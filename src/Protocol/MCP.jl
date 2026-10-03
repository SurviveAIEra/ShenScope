server_mcp_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa MCPControlTool)

function mcp_query_context(server::CoreServer, session::Session)
    prior = get(server.contexts, session.id, nothing)
    policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
    request = PermissionRequest("query", :read, "mcp.query", server.root, "Read MCP connection metadata")
    permission_decision(policy, request) == Allow || throw(ShenScopeError(:permission, "Reading MCP metadata requires approval"))
    RuntimeContext(server.root; session_id = session.id, state_dir = server.state_dir, permissions = policy,
        budget = prior === nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
end

function mcp_rpc(server::CoreServer, method::String, params::AbstractDict)
    tool = server_mcp_tool(server)
    manager = tool.manager
    session = server_session(server, params)
    if method == "mcp/query"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_schema(arguments, tool_schema(tool))
        get(arguments, "action", "") in ("servers", "status") || throw(RPCFault(-32602, "Use mcp/start for MCP network or process operations"))
        return execute(tool, arguments, mcp_query_context(server, session))
    elseif method in ("mcp/job", "mcp/cancel_job")
        id = rpc_string(params, "job_id"; max_bytes = 128)
        return lock(manager.mutex) do
            job = get(manager.jobs, id, nothing)
            job === nothing && throw(ShenScopeError(:mcp_job, "MCP job does not exist"))
            job.context.session_id == session.id && job.context.root == server.root ||
                throw(ShenScopeError(:permission, "MCP job belongs to another session"))
            method == "mcp/cancel_job" && cancel!(job.context.cancellation, "MCP job cancelled")
            mcp_job_view(job)
        end
    elseif method == "mcp/start"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_schema(arguments, tool_schema(tool))
        action = arguments["action"]
        action in ("servers", "status") && throw(RPCFault(-32602, "Use mcp/query for metadata actions"))
        name = mcp_required(arguments, "server")
        haskey(manager.specs, name) || throw(ShenScopeError(:mcp_config, "MCP server is not configured"))
        prior = get(server.contexts, session.id, nothing)
        owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
        ctx = child_context(owner)
        job = MCPJob(string(uuid4()), name, action, ctx, :running, nothing, nothing, nothing)
        lock(manager.mutex) do
            count(value -> value.status == :running, values(manager.jobs)) < 8 ||
                throw(ShenScopeError(:mcp_capacity, "MCP job concurrency limit reached"))
            if length(manager.jobs) >= 64
                done = sort!([id for (id, value) in manager.jobs if value.status != :running])
                isempty(done) && throw(ShenScopeError(:mcp_capacity, "MCP job capacity reached"))
                delete!(manager.jobs, first(done))
            end
            manager.jobs[job.id] = job
        end
        job.task = @async with_context(ctx) do
            try
                result = execute(tool, arguments, ctx; owner)
                lock(manager.mutex) do; job.result = result; job.status = :complete; end
                emit!(ctx, :mcp_job_completed, mcp_job_view(job))
            catch cause
                lock(manager.mutex) do
                    job.status = iscancelled(ctx.cancellation) ? :cancelled : :failed
                    job.error = cause isa ShenScopeError ? cause.message : cause isa MCPRemoteError ? "MCP server rejected the request" : "MCP job failed"
                end
                emit!(ctx, :mcp_job_failed, mcp_job_view(job))
            end
        end
        return Dict("job_id" => job.id, "started" => true)
    end
    throw(RPCFault(-32601, "MCP method not found"))
end
