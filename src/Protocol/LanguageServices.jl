server_language_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa LanguageTool)

function language_event_payload(server::CoreServer, event::AgentEvent, payload)
    job = event.kind in (:language_job_completed, :language_job_failed)
    tool = event.kind == :tool_completed && payload isa AbstractDict && get(payload, "name", nothing) == "language"
    job || tool || return payload
    owner = get(server.contexts, event.session_id, nothing)
    policy = owner === nothing ? permissions_from_config(server.config) : owner.permissions
    permission_decision(policy, PermissionRequest("language-delivery", :read, "language", server.root,
        "Deliver language-service evidence")) != Deny && return payload
    hidden = deepcopy(payload)
    hidden[job ? "result" : "value"] = nothing
    hidden["result_hidden_by_permission"] = true
    hidden
end

function language_rpc(server::CoreServer, method::String, params::AbstractDict)
    method in ("language/start", "language/query", "language/job", "language/cancel") ||
        throw(RPCFault(-32601, "Unknown language-service method"))
    session = server_session(server, params)
    tool = server_language_tool(server)
    prior = get(server.contexts, session.id, nothing)
    owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
    if method in ("language/job", "language/cancel")
        language_fields(params, ["session_id", "job_id"], String[], "language job controller")
        result = owned_operation(tool.operations, params["job_id"], owner; cancel=method == "language/cancel")
        if permission_decision(owner.permissions, PermissionRequest("language-job", :read, "language", server.root,
                "Read retained language operation")) != Allow
            result["result_hidden_by_permission"] = result["result"] !== nothing
            result["result"] = nothing
        end
        return result
    end
    arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
    validate_tool_arguments(tool, arguments)
    if method == "language/query"
        action = arguments["action"]
        (action in ("status", "problems", "configured", "configuration") || action == "diagnostics" && get(arguments, "mode", "cached") == "cached") ||
            throw(RPCFault(-32602, "Use language/start for language-server communication and lifecycle changes"))
        permission_decision(owner.permissions, PermissionRequest("language-query", :read, "language", server.root,
            "Read cached language-service evidence")) == Allow ||
            throw(ShenScopeError(:permission, "Use an asynchronous language operation for Read approval"))
        context = child_context(owner)
        context.approve = request -> :deny
        context.sink = event -> event.kind in (:permission_request, :permission_resolved) ? nothing : owner.sink(event)
        return execute(tool, arguments, context)
    end
    idle_session(server, params)
    start_operation!(tool.operations, owner; kind=String(arguments["action"]),
        metadata=Dict("automatic_restart" => false, "automatic_replay" => false)) do context
        execute(tool, arguments, context)
    end
end
