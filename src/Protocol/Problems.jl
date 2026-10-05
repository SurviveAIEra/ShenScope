server_problems_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa ProblemsTool)

function problems_event_payload(server::CoreServer, event::AgentEvent, payload)
    job = event.kind in (:problems_job_completed, :problems_job_failed)
    tool = event.kind == :tool_completed && payload isa AbstractDict && get(payload, "name", nothing) == "problems"
    job || tool || return payload
    owner = get(server.contexts, event.session_id, nothing)
    policy = owner === nothing ? permissions_from_config(server.config) : owner.permissions
    permission_decision(policy, PermissionRequest("problems-delivery", :read, "problems",
        server.root, "Deliver reported project diagnostics")) != Deny && return payload
    hidden = deepcopy(payload)
    hidden[job ? "result" : "value"] = nothing
    hidden["result_hidden_by_permission"] = true
    hidden
end

function problems_rpc(server::CoreServer, method::String, params::AbstractDict)
    method in ("problems/start", "problems/query", "problems/job", "problems/cancel") ||
        throw(RPCFault(-32601, "Unknown project problem method"))
    session = server_session(server, params)
    tool = server_problems_tool(server)
    prior = get(server.contexts, session.id, nothing)
    owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
    if method in ("problems/job", "problems/cancel")
        problem_fields(params, ["session_id", "job_id"], String[], "problem job controller")
        view = owned_operation(tool.operations, params["job_id"], owner; cancel=method == "problems/cancel")
        if permission_decision(owner.permissions, PermissionRequest("problems-job", :read, "problems",
                server.root, "Read diagnostic operation result")) != Allow
            view["result_hidden_by_permission"] = view["result"] !== nothing
            view["result"] = nothing
        end
        return view
    end
    arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
    validate_tool_arguments(tool, arguments)
    if method == "problems/query"
        arguments["action"] != "capture" || throw(RPCFault(-32602, "Use problems/start for diagnostic capture"))
        permission_decision(owner.permissions, PermissionRequest("problems-query", :read, "problems",
            server.root, "Read reported project diagnostics")) == Allow ||
            throw(ShenScopeError(:permission, "Use problems/start for a permissioned diagnostic read"))
        context = child_context(owner)
        context.approve = request -> :deny
        context.sink = event -> event.kind in (:permission_request, :permission_resolved) ? nothing : owner.sink(event)
        return execute(tool, arguments, context)
    end
    idle_session(server, params)
    start_operation!(tool.operations, owner; kind=String(arguments["action"]),
        metadata=Dict("automatic_execution" => false, "automatic_replay" => false)) do context
        execute(tool, arguments, context)
    end
end
