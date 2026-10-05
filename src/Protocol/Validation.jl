server_validation_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa ValidationTool)

function validation_event_payload(server::CoreServer,event::AgentEvent,payload)
    job = event.kind in (:validation_job_completed,:validation_job_failed)
    tool = event.kind == :tool_completed && payload isa AbstractDict && get(payload,"name",nothing) == "validation"
    job || tool || return payload
    owner = get(server.contexts,event.session_id,nothing)
    policy = owner === nothing ? permissions_from_config(server.config) : owner.permissions
    permission_decision(policy,PermissionRequest("validation-delivery",:read,"validation",server.root,
        "Deliver captured project check output")) != Deny && return payload
    hidden=deepcopy(payload)
    hidden[job ? "result" : "value"] = nothing
    hidden["result_hidden_by_permission"] = true
    hidden
end

function validation_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("validation/start","validation/query","validation/job","validation/cancel") ||
        throw(RPCFault(-32601,"Unknown project validation method"))
    session=server_session(server,params)
    tool=server_validation_tool(server)
    prior=get(server.contexts,session.id,nothing)
    owner=prior === nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    if method in ("validation/job","validation/cancel")
        workspace_edit_fields(params,["session_id","job_id"],String[],"validation operation controller")
        result=owned_operation(tool.operations,params["job_id"],owner;cancel=method == "validation/cancel")
        if permission_decision(owner.permissions,PermissionRequest("validation-job",:read,"validation",server.root,
                "Read project check receipt")) != Allow
            result["result_hidden_by_permission"] = result["result"] !== nothing
            result["result"] = nothing
        end
        return result
    end
    arguments=Dict{String,Any}(key=>value for (key,value) in params if key != "session_id")
    validate_tool_arguments(tool,arguments)
    if method == "validation/query"
        arguments["action"] in ("get","list","sources","compare") || throw(RPCFault(-32602,"Use validation/start to run a check or import a report"))
        permission_decision(owner.permissions,PermissionRequest("validation-query",:read,"validation",server.root,
            "Inspect project check receipts")) == Allow || throw(ShenScopeError(:permission,"Use an asynchronous validation read for approval"))
        context = child_context(owner)
        context.approve = request -> :deny
        context.sink = event -> event.kind in (:permission_request, :permission_resolved) ? nothing : owner.sink(event)
        return execute(tool,arguments,context)
    end
    idle_session(server,params)
    start_operation!(tool.operations,owner;kind=String(arguments["action"]),
        metadata=Dict("explicit_command_execution"=>arguments["action"] == "run","automatic_replay"=>false)) do context
        execute(tool,arguments,context)
    end
end
