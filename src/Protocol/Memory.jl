server_memory_tool(server::CoreServer)=only(tool for tool in server.tools if tool isa MemoryTool)

function memory_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("memory/query","memory/start","memory/job","memory/cancel_job") ||
        throw(RPCFault(-32601,"Unknown memory service method"))
    if method!="memory/start"
        allowed=method=="memory/query" ? ("session_id","scope","namespace") : ("session_id","job_id")
        all(key->key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown memory service parameter"))
    end
    session=server_session(server,params);tool=server_memory_tool(server)
    if method in ("memory/job","memory/cancel_job")
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        view=owned_operation(tool.manager.operations,rpc_string(params,"job_id";max_bytes=128),ctx;
            cancel=method=="memory/cancel_job")
        prior=get(server.contexts,session.id,nothing)
        policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        metadata=view["metadata"]
        target=String(get(metadata,"scope","workspace"))*":"*String(get(metadata,"namespace",MEMORY_DEFAULT_NAMESPACE))
        if view["result"]!==nothing && permission_decision(policy,PermissionRequest("memory-result",:read,
                "memory.result",target,"Read a retained memory result"))==Deny
            view["result"]=nothing;view["result_hidden_by_permission"]=true
        end
        return view
    elseif method=="memory/query"
        prior=get(server.contexts,session.id,nothing)
        policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
        scope=Symbol(rpc_string(params,"scope";default="workspace",max_bytes=16))
        namespace=rpc_string(params,"namespace";default=MEMORY_DEFAULT_NAMESPACE,max_bytes=64)
        ctx=RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy,
            budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget)
        store=memory_store(ctx,scope;namespace)
        permission_decision(policy,PermissionRequest("memory-query",:read,"memory.inventory",memory_target(store),
            "Read memory inventory"))==Allow || throw(ShenScopeError(:permission,"Use memory/start for permissioned memory reads"))
        return memory_inventory(store,ctx)
    end
    # Explicit client operations use normal approvals. A memory job prevents
    # concurrent conversation mutation while its state/provenance is captured.
    idle_session(server,params)
    args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
    validate_schema(args,tool_schema(tool));action=memory_action_arguments(args)
    namespace=memory_namespace(get(args,"namespace",MEMORY_DEFAULT_NAMESPACE))
    prior=get(server.contexts,session.id,nothing)
    owner=prior===nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    arguments=deepcopy(args)
    start_operation!(tool.manager.operations,owner;kind=String(action),metadata=Dict(
            "scope"=>get(args,"scope","workspace"),"namespace"=>namespace,
            "persistent_effect"=>action in ("put","delete","import"))) do context
        value=execute(tool,arguments,context;user_requested=true)
        action=="get" ? Dict("entry"=>value) : value isa AbstractDict ? value : Dict("items"=>value)
    end
end
