server_diagnostics_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa DiagnosticsTool)

function diagnostics_hide_evidence!(view::AbstractDict)
    view["result_hidden_by_permission"]=get(view,"result",nothing)!==nothing
    view["result"]=nothing;view["committed_effects"]=Any[]
    view["commit_evidence_hidden_by_permission"]=true
    view
end

function diagnostics_event_payload(server::CoreServer,event::AgentEvent)
    event.kind in (:compiler_archive_committed,:diagnostics_job_completed,:diagnostics_job_failed) || return event.payload
    owner=get(server.contexts,event.session_id,nothing)
    policy=owner===nothing ? permissions_from_config(server.config) : owner.permissions
    denied=permission_decision(policy,PermissionRequest("diagnostics-delivery",:read,"runtime.diagnostics",
        server.root,"Deliver compiler evidence"))==Deny
    denied || return event.payload
    event.kind==:compiler_archive_committed && return Dict("evidence_hidden_by_permission"=>true)
    diagnostics_hide_evidence!(deepcopy(event.payload))
end

function diagnostics_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("diagnostics/query","diagnostics/start","diagnostics/job","diagnostics/cancel_job") ||
        throw(RPCFault(-32601,"Unknown compiler diagnostics method"))
    session=server_session(server,params);tool=server_diagnostics_tool(server)
    prior=get(server.contexts,session.id,nothing)
    policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
    if method in ("diagnostics/job","diagnostics/cancel_job")
        all(key->key in ("session_id","job_id"),keys(params)) || throw(RPCFault(-32602,"Unknown diagnostics job parameter"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        view=owned_operation(tool.operations,rpc_string(params,"job_id";max_bytes=128),ctx;
            cancel=method=="diagnostics/cancel_job")
        if permission_decision(policy,PermissionRequest("diagnostics-result",:read,
                "runtime.diagnostics",server.root,"Read compiler evidence"))==Deny
            diagnostics_hide_evidence!(view)
        end
        return view
    end
    args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
    validate_schema(args,tool_schema(tool))
    diagnostics_arguments(args)
    if method=="diagnostics/query"
        (args["action"] in ("contracts","ambiguities","targets","archive_list","archive_get","archive_compare") ||
            args["action"]=="archive_gc" && get(args,"dry_run",true)) ||
            throw(RPCFault(-32602,"Use diagnostics/start for inference or archive mutations"))
        permission_decision(policy,PermissionRequest("diagnostics-query",:read,"runtime.diagnostics",server.root,
            "Read compiler metadata or owned recorded evidence"))==Allow || throw(ShenScopeError(:permission,"Use diagnostics/start for permissioned reads"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy,
            budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
        return execute(tool,args,ctx)
    end
    idle_session(server,params)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    arguments=deepcopy(args)
    start_operation!(tool.operations,owner;kind=String(args["action"]),metadata=Dict(
            "target"=>get(args,"target",""),"mode"=>get(args,"mode",args["action"]=="compile_archive" ? "graph" : "typed"),
            "trusted_core_only"=>true)) do context
        result=execute(tool,arguments,context)
        permission_decision(context.permissions,PermissionRequest("diagnostics-publication",:read,"runtime.diagnostics",
            context.root,"Publish compiler result"))==Deny &&
            throw(ShenScopeError(:permission,"Compiler result reads were revoked before delivery"))
        result isa AbstractDict ? result : Dict("items"=>result)
    end
end
