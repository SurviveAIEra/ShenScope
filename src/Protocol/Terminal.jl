server_terminal_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa TerminalTool)
function terminal_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("terminal/query","terminal/start","terminal/job","terminal/cancel_job") ||
        throw(RPCFault(-32601,"Unknown terminal method"))
    session=server_session(server,params);tool=server_terminal_tool(server)
    prior=get(server.contexts,session.id,nothing)
    policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
    if method in ("terminal/job","terminal/cancel_job")
        all(key->key in ("session_id","job_id"),keys(params)) || throw(RPCFault(-32602,"Unknown terminal job parameter"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        view=owned_operation(tool.manager.operations,rpc_string(params,"job_id";max_bytes=128),ctx;cancel=method=="terminal/cancel_job")
        if view["result"]!==nothing && permission_decision(policy,PermissionRequest("terminal-result",:read,
                "terminal.inventory",server.root,"Read retained terminal job result"))==Deny
            view["result"]=nothing;view["result_hidden_by_permission"]=true
        end
        return view
    end
    args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
    validate_schema(args,tool_schema(tool))
    if method=="terminal/query"
        args["action"] in ("platform","list","poll") || throw(RPCFault(-32602,"Use terminal/start for terminal mutations"))
        category_target=args["action"]=="poll" ? get(args,"handle","") : server.root
        permission_tool=args["action"]=="poll" ? "terminal.output" : "terminal.inventory"
        permission_decision(policy,PermissionRequest("terminal-query",:read,permission_tool,category_target,"Read terminal state"))==Allow ||
            throw(ShenScopeError(:permission,"Use terminal/start for permissioned terminal reads"))
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy,
            budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
        return execute(tool,args,ctx)
    end
    idle_session(server,params)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    start_operation!(tool.manager.operations,owner;kind=String(args["action"]),
            metadata=Dict("handle"=>get(args,"handle",""),"backend"=>"linux-openpty-v1")) do context
        execute(tool,args,context)
    end
end
