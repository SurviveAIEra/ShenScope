function hook_outcome_view(outcome::HookOutcome)
    Dict("invocation_id"=>outcome.invocation_id, "hook_id"=>outcome.hook_id, "point"=>HOOK_POINT_NAMES[outcome.point],
        "status"=>String(outcome.status), "decision"=>String(outcome.decision), "reason"=>outcome.reason,
        "error"=>outcome.error, "exit_code"=>outcome.exit_code, "duration_seconds"=>outcome.duration,
        "stdout_bytes"=>outcome.stdout_bytes, "stderr_bytes"=>outcome.stderr_bytes, "stdin_written"=>outcome.stdin_written, "context_bytes"=>ncodeunits(outcome.context))
end

function hook_environment(spec::HookSpec, ctx::RuntimeContext, lookup::Function)
    environment = Dict(key=>ENV[key] for key in ("PATH", "SYSTEMROOT", "WINDIR", "LANG", "LC_ALL", "TMPDIR", "TEMP", "TMP") if haskey(ENV, key))
    redactions = String[]
    for (name, source) in spec.environment_env
        value = lookup(source)
        value isa AbstractString && isvalid(value) && !occursin('\0', value) && 0 < ncodeunits(value) <= 65536 ||
            throw(ShenScopeError(:hook_credentials, "Configured Hook environment value is missing or invalid"))
        environment[name] = String(value); push!(redactions, String(value))
    end
    environment["SHENSCOPE_ROOT"] = ctx.root
    environment["SHENSCOPE_SESSION_ID"] = ctx.session_id
    environment["SHENSCOPE_HOOK_ID"] = spec.id
    environment["SHENSCOPE_HOOK_POINT"] = HOOK_POINT_NAMES[spec.point]
    sum(ncodeunits(key)+ncodeunits(value) for (key, value) in environment; init=0) <= 256 * 1024 ||
        throw(ShenScopeError(:hook_credentials, "Hook environment exceeds capacity"))
    environment, redactions
end

function hook_redact(value::AbstractString, redactions::Vector{String})
    text = String(value)
    for secret in sort(unique(redactions); by=ncodeunits, rev=true)
        text = replace(text, secret=>"[redacted]")
    end
    text
end

function hook_parse_output(text::String, spec::HookSpec, redactions::Vector{String})
    isempty(strip(text)) && return (:continue, nothing, "")
    ncodeunits(text) <= spec.output_limit && isvalid(text) || throw(ShenScopeError(:hook_output, "Hook output exceeds capacity or is invalid UTF-8"))
    # This protocol is deliberately small; reject excessive nesting before JSON parsing.
    depth = 0; quoted = false; escaped = false; quote_start=0; fields=Set{String}()
    bytes=codeunits(text)
    for (index,byte) in enumerate(bytes)
        if quoted
            if escaped; escaped=false
            elseif byte == 0x5c; escaped=true
            elseif byte == 0x22
                quoted=false
                after=index+1
                while after <= length(bytes) && bytes[after] in (0x20,0x09,0x0a,0x0d);after+=1;end
                if depth == 1 && after <= length(bytes) && bytes[after] == 0x3a
                    key=try String(JSON3.read(String(copy(bytes[quote_start:index])))) catch;throw(ShenScopeError(:hook_output,"Invalid Hook output field"));end
                    key in fields && throw(ShenScopeError(:hook_output,"Duplicate Hook output fields are not allowed"))
                    push!(fields,key)
                end
            end
        elseif byte == 0x22; quoted=true;quote_start=index
        elseif byte in (0x7b, 0x5b)
            depth += 1
            depth <= 4 || throw(ShenScopeError(:hook_output, "Hook output nesting exceeds capacity"))
        elseif byte in (0x7d, 0x5d); depth -= 1
        end
    end
    value = try parsejson(text) catch; throw(ShenScopeError(:hook_output, "Hook output is malformed JSON")); end
    value isa AbstractDict && all(key -> key in ("version", "decision", "reason", "context"), keys(value)) ||
        throw(ShenScopeError(:hook_output, "Hook output contains unsupported fields"))
    get(value, "version", 1) === 1 || throw(ShenScopeError(:hook_output, "Unsupported Hook output version"))
    decision = get(value, "decision", "continue")
    decision in ("continue", "deny", "stop") || throw(ShenScopeError(:hook_output, "Hook decision must be continue, deny or stop"))
    decision != "continue" && !(spec.point in HOOK_PRE_POINTS) &&
        throw(ShenScopeError(:hook_output, "Post-effect Hook cannot revoke a completed operation"))
    reason = get(value, "reason", nothing)
    reason === nothing || reason isa AbstractString && isvalid(reason) && ncodeunits(reason) <= 1024 ||
        throw(ShenScopeError(:hook_output, "Hook reason exceeds capacity"))
    context = get(value, "context", "")
    context isa AbstractString && isvalid(context) && ncodeunits(context) <= 4096 || throw(ShenScopeError(:hook_output, "Hook context exceeds capacity"))
    !isempty(context) && !spec.allow_context && throw(ShenScopeError(:hook_output, "Context output is not enabled for this Hook"))
    Symbol(decision), reason === nothing ? nothing : hook_redact(reason, redactions), hook_redact(context, redactions)
end

function hook_metadata(point::HookPoint, metadata::AbstractDict)
    allowed = Set(["tool", "call_id", "worker", "provider", "model", "step", "ok", "exit_code", "status", "finish", "estimated_input_tokens", "input_tokens", "output_tokens"])
    all(key -> key in allowed, keys(metadata)) || throw(ShenScopeError(:hook_payload, "Hook input must contain only lifecycle metadata"))
    result = Dict{String,Any}()
    for (key, value) in metadata
        if value isa AbstractString
            isvalid(value) && ncodeunits(value) <= 256 || throw(ShenScopeError(:hook_payload, "Hook metadata string exceeds capacity"))
            result[String(key)] = String(value)
        elseif value isa Bool || value === nothing || value isa Int
            result[String(key)] = value
        else
            throw(ShenScopeError(:hook_payload, "Hook metadata requires scalar values"))
        end
    end
    result
end

function run_hook!(manager::HookManager, catalog::HookCatalog, spec::HookSpec, owner::RuntimeContext;
        metadata=Dict{String,Any}(), testing=false)
    hook_enabled(manager, spec) || throw(ShenScopeError(:hook_disabled, "Hook is disabled"))
    data = hook_metadata(spec.point, metadata)
    ctx = child_context(owner)
    invocation = HookInvocation(string(uuid4()), spec.id, ctx, nothing)
    lock(manager.mutex) do
        length(manager.active) < 8 || throw(ShenScopeError(:hook_capacity, "Hook process concurrency limit reached"))
        manager.active[invocation.id] = invocation
    end
    started = time()
    status=:failed; decision=:continue; reason=nothing; context=""; error=nothing; exit_code=nothing
    stdout_bytes=0; stderr_bytes=0; stdin_written=false; lease=nothing; handle=nothing
    try
        emit!(ctx, :hook_invoked, Dict("invocation_id"=>invocation.id, "hook_id"=>spec.id, "name"=>spec.name,
            "point"=>HOOK_POINT_NAMES[spec.point], "source"=>spec.source, "testing"=>testing))
        with_context(ctx) do
            validate_hook_source!(manager, catalog, spec, ctx)
            environment, redactions = hook_environment(spec, ctx, manager.credential_lookup)
            lease = reserve!(ctx.budget, 0, 0.0)
            status_budget = budget_status(ctx.budget)
            remaining = status_budget["limits"]["max_seconds"] - status_budget["elapsed_seconds"]
            remaining >= 0.05 || throw(ShenScopeError(:budget, "Hook wall-clock budget exhausted"))
            target = canonical(Dict("hook_id"=>spec.id, "source_sha256"=>spec.source_sha256,
                "declaration_sha256"=>spec.declaration_sha256, "argv"=>spec.argv,
                "cwd"=>workspace_path(ctx.root, spec.cwd), "environment_sources"=>spec.environment_env))
            handle = start_process!(manager.process, spec.argv, ctx; cwd=spec.cwd, timeout=min(spec.timeout, remaining),
                output_limit=spec.output_limit, environment, emit_output=false, permission_target=target, permission_tool="hooks.run",
                before_start=()->begin
                    validate_hook_source!(manager, catalog, spec, ctx; authorized=true)
                    runtime = ACTIVE_HOOK_RUNTIME[]
                    !spec.replay_safe && runtime !== nothing && runtime.effect_observer(spec)
                    validate_hook_source!(manager, catalog, spec, ctx; authorized=true)
                    lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
                end)
            lock(manager.mutex) do; invocation.process=handle; end
            payload = canonical(Dict("version"=>1, "invocation_id"=>invocation.id, "hook_id"=>spec.id,
                "point"=>HOOK_POINT_NAMES[spec.point], "root"=>ctx.root, "session_id"=>ctx.session_id, "testing"=>testing, "metadata"=>data))
            ncodeunits(payload) <= 32 * 1024 || throw(ShenScopeError(:hook_payload, "Hook input exceeds capacity"))
            stdin_written=process_input!(handle, payload * "\n", ctx;allow_closed_input=true)
            wait(handle.monitor)
            result = process_status(handle)
            stdout_bytes=result["stdout_bytes"]; stderr_bytes=result["stderr_bytes"]; exit_code=result["exit_code"]
            check_cancelled(ctx.cancellation)
            result["timed_out"] && throw(ShenScopeError(:timeout, "Hook process timed out"))
            exit_code == 0 || throw(ShenScopeError(:hook_exit, "Hook process reported a failure"))
            stdout_bytes <= spec.output_limit || throw(ShenScopeError(:hook_output, "Hook output was truncated; decisions are not parsed from partial output"))
            raw_output = String(output_bytes(handle.stdout))
            decision, reason, context = hook_parse_output(raw_output, spec, redactions)
            status = decision == :continue ? :complete : :blocked
        end
    catch cause
        cause isa InterruptException && rethrow()
        code = cause isa ShenScopeError ? cause.code : :hook_internal
        status = iscancelled(ctx.cancellation) ? :cancelled : code == :timeout ? :timed_out : code == :permission ? :denied : :failed
        error = cause isa ShenScopeError ? cause.message : "Hook execution failed"
        decision = spec.on_failure == :deny && spec.point in HOOK_PRE_POINTS ? :deny : :continue
        context = ""; reason=nothing
    finally
        if handle !== nothing
            terminate_process!(handle)
            try wait(handle.monitor) catch end
            result = process_status(handle)
            stdout_bytes=result["stdout_bytes"]; stderr_bytes=result["stderr_bytes"]; exit_code=result["exit_code"]
            lock(manager.process.mutex) do; delete!(manager.process.handles, handle.id); end
        end
        lease !== nothing && release!(ctx.budget, lease)
        lock(manager.mutex) do; delete!(manager.active, invocation.id); end
    end
    outcome = HookOutcome(invocation.id, spec.id, spec.point, status, decision, reason, context, error,
        exit_code, time()-started, stdout_bytes, stderr_bytes, stdin_written)
    view = merge(hook_outcome_view(outcome), Dict("name"=>spec.name, "source"=>spec.source, "root"=>ctx.root,
        "session_id"=>ctx.session_id, "timestamp"=>utcstamp(), "testing"=>testing))
    lock(manager.mutex) do
        push!(manager.history, view)
        length(manager.history) > manager.config.max_history && deleteat!(manager.history, 1:length(manager.history)-manager.config.max_history)
    end
    emit!(ctx, :hook_result, view)
    outcome
end
