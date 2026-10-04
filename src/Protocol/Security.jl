server_security_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa SecurityTool)

function security_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("security/query","security/start","security/job","security/cancel_job") ||
        throw(RPCFault(-32601,"Unknown security service method"))
    allowed=method=="security/query" ? ("session_id",) : method=="security/start" ? ("session_id","action") : ("session_id","job_id")
    all(key->key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown security argument"))
    tool=server_security_tool(server);session=server_session(server,params)
    if method in ("security/job","security/cancel_job")
        scope=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        view=owned_operation(tool.manager.operations,rpc_string(params,"job_id";max_bytes=128),scope;
            cancel=method=="security/cancel_job")
        prior=get(server.contexts,session.id,nothing)
        policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        if view["result"]!==nothing && permission_decision(policy,PermissionRequest("security-result",:read,
                "security.result",server.root,"Read retained security metadata"))==Deny
            view["result"]=nothing;view["result_hidden_by_permission"]=true
        end
        return view
    elseif method=="security/query"
        prior=get(server.contexts,session.id,nothing)
        policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        permission_decision(policy,PermissionRequest("security-query",:read,"security.status",server.root,
            "Read execution metadata"))==Allow || throw(ShenScopeError(:permission,"Use security/start for permissioned status"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy,
            sandbox=sandbox_from_config(server.config),budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
        return execution_status(tool.manager,ctx)
    end
    idle_session(server,params)
    action=rpc_string(params,"action";default="probe",max_bytes=16)
    action in ("status","probe") || throw(RPCFault(-32602,"Unknown security action"))
    prior=get(server.contexts,session.id,nothing)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    start_operation!(tool.manager.operations,owner;kind=action,
            metadata=Dict("backend"=>"bubblewrap","persistent_effect"=>false)) do context
        execute(tool,Dict("action"=>action),context)
    end
end
