server_workspace_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa WorkspaceTool)

function workspace_event_payload(server::CoreServer, event::AgentEvent, payload)
    job = event.kind in (:workspace_job_completed, :workspace_job_failed)
    tool = event.kind == :tool_completed && payload isa AbstractDict && get(payload, "name", nothing) == "workspace"
    finished = event.kind == :workspace_edits_finished
    job || tool || finished || return payload
    owner = get(server.contexts, event.session_id, nothing)
    policy = owner === nothing ? permissions_from_config(server.config) : owner.permissions
    permission_decision(policy, PermissionRequest("workspace-delivery", :read, "workspace", server.root,
        "Deliver workspace change evidence")) != Deny && return payload
    finished && return Dict("evidence_hidden_by_permission" => true)
    hidden = deepcopy(payload)
    hidden[job ? "result" : "value"] = nothing
    hidden["result_hidden_by_permission"] = true
    hidden
end

function workspace_rpc(server::CoreServer, method::String, params::AbstractDict)
    method in ("workspace/start", "workspace/query", "workspace/job", "workspace/cancel") ||
        throw(RPCFault(-32601, "Unknown workspace change method"))
    session = server_session(server, params)
    tool = server_workspace_tool(server)
    prior = get(server.contexts, session.id, nothing)
    owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
    if method in ("workspace/job", "workspace/cancel")
        workspace_edit_fields(params, ["session_id", "job_id"], String[], "workspace operation controller")
        result = owned_operation(tool.operations, params["job_id"], owner; cancel=method == "workspace/cancel")
        if permission_decision(owner.permissions, PermissionRequest("workspace-job", :read, "workspace",
                server.root, "Read workspace change receipt")) != Allow
            result["result_hidden_by_permission"] = result["result"] !== nothing
            result["result"] = nothing
        end
        return result
    end
    arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
    validate_tool_arguments(tool, arguments)
    if method == "workspace/query"
        arguments["action"] in ("list", "get", "preview", "source", "history_list", "history_get", "history_sources") ||
            throw(RPCFault(-32602, "Use workspace/start for preparing or applying changes and running validation"))
        permission_decision(owner.permissions, PermissionRequest("workspace-query", :read, "workspace",
            server.root, "Inspect owned workspace changes")) == Allow ||
            throw(ShenScopeError(:permission, "Use an asynchronous workspace operation for Read approval"))
        context = child_context(owner)
        context.approve = request -> :deny
        context.sink = event -> event.kind in (:permission_request, :permission_resolved) ? nothing : owner.sink(event)
        return execute(tool, arguments, context)
    end
    idle_session(server, params)
    start_operation!(tool.operations, owner; kind=String(arguments["action"]),
        metadata=Dict("explicit_workspace_changes" => arguments["action"] == "apply",
            "explicit_command_execution" => arguments["action"] == "verify", "automatic_replay" => false)) do context
        execute(tool, arguments, context)
    end
end
