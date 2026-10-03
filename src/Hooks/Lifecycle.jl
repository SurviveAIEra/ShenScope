function with_lifecycle_hooks(callback::Function, tools, ctx::RuntimeContext; effect_observer=nothing)
    prior = ACTIVE_HOOK_RUNTIME[]
    managers = [tool.manager for tool in tools if tool isa HooksTool]
    length(managers) <= 1 || throw(ShenScopeError(:extension, "Only one Hook manager may own a runtime"))
    if isempty(managers)
        return prior === nothing || prior.owner === ctx ? callback() : with(callback, ACTIVE_HOOK_RUNTIME=>nothing)
    end
    manager = only(managers)
    prior !== nothing && prior.manager === manager && prior.owner === ctx && effect_observer === nothing && return callback()
    observer = effect_observer === nothing ? prior !== nothing && prior.manager === manager ? prior.effect_observer : spec->nothing : effect_observer
    runtime = HookRuntime(manager, ctx, String[], 0, false, observer, ReentrantLock())
    with(callback, ACTIVE_HOOK_RUNTIME=>runtime)
end

function hook_queue_context!(runtime::HookRuntime, spec::HookSpec, context::String)
    isempty(context) && return
    text = "Context from configured Hook " * spec.name * " (" * HOOK_POINT_NAMES[spec.point] * "):\n" * context
    retained = lock(runtime.mutex) do
        length(runtime.pending) < 16 && runtime.context_bytes + ncodeunits(text) <= 16 * 1024 || return false
        push!(runtime.pending, text); runtime.context_bytes += ncodeunits(text)
        true
    end
    retained || emit!(runtime.owner, :hook_context_dropped, Dict("hook_id"=>spec.id, "reason"=>"context_capacity"))
    nothing
end

function take_hook_context!()
    runtime = ACTIVE_HOOK_RUNTIME[]
    runtime === nothing && return ""
    lock(runtime.mutex) do
        text = join(runtime.pending, "\n\n")
        empty!(runtime.pending); runtime.context_bytes=0
        text
    end
end

function hook_stop_requested()
    runtime = ACTIVE_HOOK_RUNTIME[]
    runtime !== nothing && lock(runtime.mutex) do; runtime.stop_requested; end
end

function run_lifecycle_hooks!(point::HookPoint, ctx::RuntimeContext; metadata=Dict{String,Any}())
    runtime = ACTIVE_HOOK_RUNTIME[]
    runtime === nothing && return HookOutcome[]
    runtime.owner.root == ctx.root && runtime.owner.session_id == ctx.session_id || throw(ShenScopeError(:hook_scope, "Hook runtime belongs to another session"))
    manager = runtime.manager
    manager.config.enabled || return HookOutcome[]
    if iscancelled(ctx.cancellation)
        point == HookSessionEnd && emit!(ctx, :hook_skipped, Dict("point"=>HOOK_POINT_NAMES[point], "reason"=>"owner_cancelled"))
        check_cancelled(ctx.cancellation)
    end
    catalog = hook_catalog!(manager, ctx)
    outcomes = HookOutcome[]
    for spec in catalog.specs
        spec.point == point && hook_enabled(manager, spec) || continue
        isempty(spec.tools) || get(metadata, "tool", "") in spec.tools || continue
        outcome = run_hook!(manager, catalog, spec, ctx; metadata)
        push!(outcomes, outcome)
        check_cancelled(ctx.cancellation)
        hook_queue_context!(runtime, spec, outcome.context)
        if outcome.decision == :stop
            lock(runtime.mutex) do; runtime.stop_requested=true; end
        end
        outcome.decision != :continue && break
    end
    outcomes
end

function enforce_hook_outcomes!(outcomes::Vector{HookOutcome})
    for outcome in outcomes
        outcome.decision == :continue && continue
        throw(ShenScopeError(outcome.decision == :stop ? :hook_stopped : :hook_denied, "Configured Hook blocked the lifecycle operation"))
    end
    nothing
end

function before_tool_hooks!(call::ToolCall, ctx::RuntimeContext; worker=false)
    hook_stop_requested() && throw(ShenScopeError(:hook_stopped, "Configured Hook requested a stop"))
    enforce_hook_outcomes!(run_lifecycle_hooks!(HookBeforeTool, ctx; metadata=Dict("tool"=>call.name, "call_id"=>call.id, "worker"=>worker)))
end

function observe_lifecycle_hooks!(point::HookPoint, ctx::RuntimeContext; metadata=Dict{String,Any}())
    try
        run_lifecycle_hooks!(point, ctx; metadata)
    catch cause
        cause isa InterruptException && rethrow()
        emit!(ctx, :hook_post_error, Dict("point"=>HOOK_POINT_NAMES[point],
            "error"=>cause isa ShenScopeError ? cause.message : "Post-effect Hook failed"))
    end
    nothing
end

function after_tool_hooks!(call::ToolCall, result::ToolResult, ctx::RuntimeContext; worker=false, testing=false)
    runtime = ACTIVE_HOOK_RUNTIME[]
    runtime === nothing && return
    metadata = Dict{String,Any}("tool"=>call.name, "call_id"=>call.id, "ok"=>result.ok, "worker"=>worker)
    result.value isa AbstractDict && get(result.value, "exit_code", nothing) isa Int && (metadata["exit_code"]=result.value["exit_code"])
    points = HookPoint[HookAfterTool]
    result.ok && call.name in ("edit", "write", "patch") && push!(points, HookAfterEdit)
    testing = testing && result.value isa AbstractDict && haskey(result.value,"exit_code")
    if testing
        metadata["ok"] = get(result.value,"exit_code",-1) == 0 && !get(result.value,"timed_out",false)
        push!(points, HookAfterTest)
    end
    for point in points
        try
            run_lifecycle_hooks!(point, ctx; metadata)
        catch cause
            cause isa InterruptException && rethrow()
            # A completed side effect remains a completed tool result.
            emit!(ctx, :hook_post_error, Dict("point"=>HOOK_POINT_NAMES[point], "call_id"=>call.id,
                "error"=>cause isa ShenScopeError ? cause.message : "Post-effect Hook failed"))
        end
    end
    nothing
end

function cleanup_hooks!(manager::HookManager; session_id=nothing, root=nothing)
    active, jobs = lock(manager.mutex) do
        matches = ctx -> (session_id === nothing || ctx.session_id == session_id) && (root === nothing || ctx.root == root)
        ([item for item in values(manager.active) if matches(item.context)],
            [item for item in values(manager.jobs) if matches(item.context)])
    end
    for item in active; cancel!(item.context.cancellation, "Hook owner stopped"); end
    for job in jobs; job.status == :running && cancel!(job.context.cancellation, "Hook operation stopped"); end
    for item in active
        item.process !== nothing && terminate_process!(item.process)
    end
    for job in jobs
        job.task !== nothing && job.task !== current_task() && try wait(job.task) catch end
    end
    deadline = time() + 5
    while true
        unfinished = lock(manager.mutex) do; any(item -> haskey(manager.active, item.id), active); end
        !unfinished && break
        time() < deadline || throw(ShenScopeError(:hook_busy, "Hook operations did not drain"))
        sleep(0.01)
    end
    lock(manager.mutex) do
        for job in jobs; delete!(manager.jobs, job.id); end
        for key in collect(keys(manager.catalogs)); (root === nothing || key == root) && session_id === nothing && delete!(manager.catalogs, key); end
    end
    nothing
end
