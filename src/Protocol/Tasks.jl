server_task_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa TaskTool)

function task_query_context(server::CoreServer, session::Session)
    prior = get(server.contexts, session.id, nothing)
    policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
    request = PermissionRequest("query", :read, "tasks.query", server.root, "Read durable task state")
    permission_decision(policy, request) == Allow || throw(ShenScopeError(:permission, "Reading task state requires approval"))
    RuntimeContext(server.root; session_id = session.id, state_dir = server.state_dir, permissions = policy,
        budget = prior === nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
end

function tasks_rpc(server::CoreServer, method::String, params::AbstractDict)
    tool = server_task_tool(server)
    manager = tool.manager
    session = server_session(server, params)
    if method == "tasks/start"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_schema(arguments, tool_schema(tool))
        arguments["action"] in ("create", "run", "cancel", "recover", "reconcile") ||
            throw(RPCFault(-32602, "Use tasks/query for read actions"))
        ctx = server_context(server, session.id)
        id = string(uuid4())
        workflow_id = get(arguments, "workflow_id", "")
        provider = server.provider_factory(server)
        executor = WorkExecutor(; tools = collect(values(manager.executor.tools)), provider_factory = ctx -> provider)
        # The tool keeps the process/project owners shared with Core. Only the
        # request's provider choice is frozen for this asynchronous run.
        jobtool = TaskTool(TaskManager(executor, manager.workflows, manager.jobs, manager.mutex))
        job = WorkRun(id, workflow_id, ctx, :running, nothing, nothing, nothing)
        lock(manager.mutex) do
            count(run -> run.status == :running, values(manager.jobs)) < 8 || throw(ShenScopeError(:runtime, "Task job concurrency limit reached"))
            if arguments["action"] == "run"
                any(run -> run.status == :running && run.workflow_id == workflow_id, values(manager.jobs)) &&
                    throw(ShenScopeError(:runtime, "This workflow already has an active job"))
            end
            if length(manager.jobs) >= 64
                done = sort!([key for (key, run) in manager.jobs if run.status != :running])
                isempty(done) && throw(ShenScopeError(:runtime, "Task job capacity reached"))
                delete!(manager.jobs, first(done))
            end
            manager.jobs[id] = job
        end
        job.task = @async begin
            try
                result = with_context(() -> execute(jobtool, arguments, ctx), ctx)
                lock(manager.mutex) do
                    job.result = result
                    arguments["action"] == "create" && (job.workflow_id = result["id"])
                    job.status = :complete
                end
                emit!(ctx, :task_job_completed, work_run_view(job))
            catch error
                lock(manager.mutex) do
                    job.error = error isa ShenScopeError ? error.message : "Task job failed"
                    job.status = iscancelled(ctx.cancellation) ? :cancelled : :failed
                end
                emit!(ctx, :task_job_failed, work_run_view(job))
            end
        end
        return Dict("job_id" => id, "started" => true)
    elseif method in ("tasks/job", "tasks/cancel_job")
        id = rpc_string(params, "job_id"; max_bytes = 128)
        return lock(manager.mutex) do
            job = get(manager.jobs, id, nothing)
            job === nothing && throw(ShenScopeError(:tasks, "Task job does not exist"))
            job.context.session_id == session.id || throw(ShenScopeError(:permission, "Task job belongs to another session"))
            method == "tasks/cancel_job" && cancel!(job.context.cancellation, "Task job cancelled")
            work_run_view(job)
        end
    elseif method == "tasks/query"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_schema(arguments, tool_schema(tool))
        arguments["action"] in ("list", "status", "tasks", "get") || throw(RPCFault(-32602, "Unknown task query action"))
        return execute(tool, arguments, task_query_context(server, session))
    end
    throw(RPCFault(-32601, "Task method not found"))
end
