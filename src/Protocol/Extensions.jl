server_extensions_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa ExtensionsTool)
function extensions_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("extensions/query","extensions/start","extensions/job","extensions/cancel_job") || throw(RPCFault(-32601,"Unknown extension method"))
    session=server_session(server,params);tool=server_extensions_tool(server)
    if method in ("extensions/job","extensions/cancel_job")
        all(key->key in ("session_id","job_id"),keys(params)) || throw(RPCFault(-32602,"Unknown extension job parameter"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        view=owned_operation(tool.operations,rpc_string(params,"job_id";max_bytes=128),ctx;cancel=method=="extensions/cancel_job")
        prior=get(server.contexts,session.id,nothing);policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        if view["result"]!==nothing && permission_decision(policy,PermissionRequest("extension-result",:read,
                "extension.inventory",server.root,"Read retained extension result"))==Deny
            view["result"]=nothing;view["result_hidden_by_permission"]=true
        end
        return view
    elseif method=="extensions/query"
        all(key->key in ("session_id",),keys(params)) || throw(RPCFault(-32602,"Unknown extension query parameter"))
        prior=get(server.contexts,session.id,nothing);policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        permission_decision(policy,PermissionRequest("extension-query",:read,"extension.inventory",server.root,"Read extension inventory"))==Allow ||
            throw(ShenScopeError(:permission,"Use extensions/start for permissioned inventory reads"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy,
            budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
        return execute(tool,Dict("action"=>"list"),ctx)
    end
    idle_session(server,params)
    args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
    validate_schema(args,tool_schema(tool))
    prior=get(server.contexts,session.id,nothing)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    start_operation!(tool.operations,owner;kind=String(args["action"]),metadata=Dict(
        "name"=>get(args,"name",""),"trusted_in_process"=>true,"module_unloading_supported"=>false)) do context
        result=execute(tool,args,context)
        result isa AbstractDict ? result : Dict("value"=>result)
    end
end
