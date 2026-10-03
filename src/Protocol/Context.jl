server_context_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa ContextTool)

function context_job_view(job::ContextJob)
    Dict("job_id" => job.id, "action" => job.action, "status" => String(job.status),
        "result" => deepcopy(job.result), "error" => job.error)
end

function context_owned_job(manager::ContextManager, id::String, root::String, session_id::String)
    lock(manager.mutex) do
        job = get(manager.jobs, id, nothing)
        job !== nothing || throw(ShenScopeError(:context_job, "Context operation does not exist"))
        job.context.root == root && job.context.session_id == session_id ||
            throw(ShenScopeError(:permission, "Context operation belongs to another conversation"))
        job
    end
end

function context_jobs_running(manager::ContextManager; session_id=nothing)
    lock(manager.mutex) do
        any(job -> job.status == :running && (session_id === nothing || job.context.session_id == session_id), values(manager.jobs))
    end
end

function retain_context_job_result!(manager::ContextManager, job::ContextJob, result)
    bytes = ncodeunits(canonical(result))
    bytes <= CONTEXT_MAX_JOB_BYTES || throw(ShenScopeError(:context_capacity, "Context job result exceeds transport capacity"))
    lock(manager.mutex) do
        completed = sort!([value for value in values(manager.jobs) if value.status != :running && value.id != job.id];
            by=value -> value.finished_at)
        retained = sum(value.result_bytes for value in completed; init=0)
        for item in completed
            retained + bytes <= CONTEXT_MAX_RETAINED_BYTES && break
            delete!(manager.jobs, item.id); retained -= item.result_bytes
        end
        job.result = result; job.result_bytes = bytes; job.status = :complete; job.finished_at = time()
    end
end

function start_context_job!(server::CoreServer, session::Session, arguments::Dict{String,Any})
    haskey(server.runs, session.id) && throw(ShenScopeError(:context_busy, "Run context operations between agent turns"))
    tool = server_context_tool(server); manager = tool.manager
    prior = get(server.contexts, session.id, nothing)
    owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
    ctx = child_context(owner)
    provider = arguments["action"] == "compact" ? server.provider_factory(server) : nothing
    job = ContextJob(string(uuid4()), arguments["action"], ctx, session, :running, nothing, nothing, nothing, 0.0, 0)
    lock(manager.mutex) do
        count(value -> value.status == :running, values(manager.jobs)) < CONTEXT_MAX_ACTIVE_JOBS ||
            throw(ShenScopeError(:context_capacity, "Context job concurrency limit reached"))
        any(value -> value.status == :running && value.context.session_id == session.id, values(manager.jobs)) &&
            throw(ShenScopeError(:context_busy, "A context operation is already running in this conversation"))
        if length(manager.jobs) >= CONTEXT_MAX_JOBS
            completed = sort!([value for value in values(manager.jobs) if value.status != :running]; by=value -> value.finished_at)
            isempty(completed) && throw(ShenScopeError(:context_capacity, "Context job capacity reached"))
            delete!(manager.jobs, first(completed).id)
        end
        manager.jobs[job.id] = job
    end
    bind_context_session!(manager, session, ctx)
    job.task = @async with_context(ctx) do
        try
            result = execute(tool, arguments, ctx; user_requested=true, provider, tools=server.tools)
            check_cancelled(ctx.cancellation)
            retain_context_job_result!(manager, job, result)
            emit!(ctx, :context_job_completed, context_job_view(job))
        catch error
            lock(manager.mutex) do
                job.status = iscancelled(ctx.cancellation) ? :cancelled : :failed
                job.error = error isa ShenScopeError ? error.message : "Context operation failed"
                job.finished_at = time()
            end
            emit!(ctx, :context_job_failed, context_job_view(job))
        end
    end
    Dict("job_id" => job.id, "started" => true)
end

function context_rpc(server::CoreServer, method::String, params::AbstractDict)
    tool = server_context_tool(server); manager = tool.manager
    session = server_session(server, params)
    if method == "context/query"
        prior = get(server.contexts, session.id, nothing)
        policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
        target = "session:" * session.id
        permission_decision(policy, PermissionRequest("context-query", :read, "context.query", target, "Read cached context metadata")) == Allow ||
            throw(ShenScopeError(:permission, "Use context/start for permissioned context loading"))
        ctx = RuntimeContext(server.root; session_id=session.id, state_dir=server.state_dir, permissions=policy)
        live = lock(manager.mutex) do; get(manager.sessions, (server.root, session.id), nothing); end
        bind_context_session!(manager, live === nothing ? session : live, ctx)
        return context_status(manager, ctx)
    elseif method in ("context/job", "context/cancel_job")
        job = context_owned_job(manager, rpc_string(params, "job_id"; max_bytes=128), server.root, session.id)
        method == "context/cancel_job" && cancel!(job.context.cancellation, "Context operation cancelled")
        return lock(manager.mutex) do; context_job_view(job); end
    elseif method == "context/start"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_tool_arguments(tool, arguments)
        return start_context_job!(server, session, arguments)
    end
    throw(RPCFault(-32601, "Context method not found"))
end
