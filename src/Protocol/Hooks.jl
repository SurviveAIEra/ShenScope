server_hooks_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa HooksTool)

function hook_job_view(job::HookJob)
    Dict("job_id"=>job.id, "action"=>job.action, "status"=>String(job.status), "result"=>deepcopy(job.result), "error"=>job.error)
end

function hook_owned_job(manager::HookManager, id::String, ctx::RuntimeContext)
    lock(manager.mutex) do
        job = get(manager.jobs, id, nothing)
        job !== nothing || throw(ShenScopeError(:hook_job, "Hook operation does not exist"))
        job.context.root == ctx.root && job.context.session_id == ctx.session_id || throw(ShenScopeError(:permission, "Hook operation belongs to another session"))
        job
    end
end

function hook_configuration_path(server::CoreServer, manager::HookManager, job::HookJob)
    job.status == :complete && job.action == "source" && !job.opened && time()-job.finished_at <= 300 ||
        throw(ShenScopeError(:hook_job, "Configuration opening requires a recent completed source read"))
    check_cancelled(job.context.cancellation)
    catalog = lock(manager.mutex) do; get(manager.catalogs, server.root, nothing); end
    catalog !== nothing || throw(ShenScopeError(:hook_stale, "Hook catalog was replaced"))
    spec = hook_find(catalog, job.result["id"])
    spec.source == job.result["path"] || throw(ShenScopeError(:hook_stale, "Hook source identity changed"))
    request = PermissionRequest("hook-source-open", :read, "hooks.open_source", spec.source, "Open approved Hook configuration")
    for policy in (permissions_from_config(server.config), job.context.permissions)
        permission_decision(policy, request) == Deny && throw(ShenScopeError(:permission, "Opening Hook configuration is denied"))
    end
    raw = hook_read_source(job.context, spec.source_root, spec.source; authorized=true, maximum=spec.scope == :config ? 1024 * 1024 : 128 * 1024)
    digest(raw) == job.result["sha256"] || throw(ShenScopeError(:hook_stale, "Hook configuration changed after approval"))
    lock(manager.mutex) do
        job.opened && throw(ShenScopeError(:hook_job, "Configuration opening was already consumed"))
        job.opened=true
    end
    Dict("path"=>spec.source, "sha256"=>job.result["sha256"])
end

function hooks_rpc(server::CoreServer, method::String, params::AbstractDict)
    tool = server_hooks_tool(server); manager=tool.manager
    session = server_session(server, params)
    prior = get(server.contexts, session.id, nothing)
    if method == "hooks/query"
        policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
        ctx = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy)
        return lock(manager.mutex) do
            catalog = get(manager.catalogs, server.root, nothing)
            catalog === nothing && return Dict("indexed"=>false, "enabled"=>manager.config.enabled)
            for target in vcat([server.root], collect(keys(catalog.sources)))
                permission_decision(policy, PermissionRequest("hooks-query", :read, "hooks.query", target, "Read cached Hook metadata")) == Allow ||
                    throw(ShenScopeError(:permission, "Use hooks/start for permissioned metadata loading"))
            end
            Dict("indexed"=>true, "enabled"=>manager.config.enabled, "generation"=>catalog.generation,
                "sources"=>copy(catalog.sources), "points"=>[HOOK_POINT_NAMES[point] for point in instances(HookPoint)],
                "hooks"=>[hook_spec_view(manager, catalog, spec, ctx) for spec in catalog.specs])
        end
    elseif method in ("hooks/job", "hooks/cancel_job", "hooks/source_path")
        ctx = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        job = hook_owned_job(manager, rpc_string(params, "job_id";max_bytes=128), ctx)
        method == "hooks/source_path" && return hook_configuration_path(server, manager, job)
        method == "hooks/cancel_job" && cancel!(job.context.cancellation, "Hook operation cancelled")
        return lock(manager.mutex) do; hook_job_view(job); end
    elseif method == "hooks/start"
        arguments = Dict{String,Any}(key=>value for (key, value) in params if key != "session_id")
        validate_tool_arguments(tool, arguments)
        action = arguments["action"]
        action == "test" && haskey(server.runs, session.id) && throw(ShenScopeError(:hook_busy, "Test Hooks between agent runs"))
        action == "reload" && (!isempty(server.runs) || !isempty(manager.active)) && throw(ShenScopeError(:hook_busy, "Reload Hooks between active lifecycle executions"))
        owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
        ctx = child_context(owner)
        job = HookJob(string(uuid4()), action, ctx, :running, nothing, nothing, nothing, 0.0, false, 0)
        lock(manager.mutex) do
            count(value -> value.status == :running, values(manager.jobs)) < 8 || throw(ShenScopeError(:hook_capacity, "Hook job concurrency limit reached"))
            any(value -> value.status == :running && value.context.session_id == session.id, values(manager.jobs)) &&
                throw(ShenScopeError(:hook_busy, "A Hook operation is already running in this conversation"))
            if length(manager.jobs) >= 64
                completed = sort!([value for value in values(manager.jobs) if value.status != :running];by=value->value.finished_at)
                isempty(completed) && throw(ShenScopeError(:hook_capacity, "Hook job capacity reached"))
                delete!(manager.jobs, first(completed).id)
            end
            manager.jobs[job.id]=job
        end
        job.task = @async with_context(ctx) do
            try
                result = execute(tool, arguments, ctx;user_requested=true)
                check_cancelled(ctx.cancellation)
                bytes = ncodeunits(canonical(result))
                bytes <= 4 * 1024 * 1024 || throw(ShenScopeError(:hook_size, "Hook job result exceeds transport capacity"))
                lock(manager.mutex) do
                    completed = sort!([value for value in values(manager.jobs) if value.status != :running && value.id != job.id];by=value->value.finished_at)
                    retained = sum(value.result_bytes for value in completed;init=0)
                    for item in completed
                        retained+bytes <= 16 * 1024 * 1024 && break
                        delete!(manager.jobs, item.id);retained-=item.result_bytes
                    end
                    job.result=result;job.result_bytes=bytes;job.status=:complete;job.finished_at=time()
                end
                emit!(ctx, :hooks_job_completed, hook_job_view(job))
            catch cause
                lock(manager.mutex) do
                    job.status=iscancelled(ctx.cancellation) ? :cancelled : :failed
                    job.error=cause isa ShenScopeError ? cause.message : "Hook operation failed"
                    job.finished_at=time()
                end
                emit!(ctx, :hooks_job_failed, hook_job_view(job))
            end
        end
        return Dict("job_id"=>job.id, "started"=>true)
    end
    throw(RPCFault(-32601, "Hooks method not found"))
end
