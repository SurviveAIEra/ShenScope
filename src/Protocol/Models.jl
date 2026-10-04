server_models_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa ModelsTool)

function models_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("models/query","models/start","models/job","models/cancel_job") || throw(RPCFault(-32601,"Unknown model service method"))
    if method != "models/start"
        allowed = method == "models/query" ? ("session_id","offset","limit") : ("session_id","job_id")
        all(key -> key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown model service parameter"))
    end
    session = server_session(server,params);tool = server_models_tool(server)
    prior = get(server.contexts,session.id,nothing)
    if method == "models/query"
        policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
        permission_decision(policy,PermissionRequest("models-query",:read,"models.catalog",server.root,"Read cached model catalog")) == Allow ||
            throw(ShenScopeError(:permission,"Use models/start for permissioned model metadata reads"))
        ctx = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy)
        return Dict("status"=>model_services_status(tool.provider),"catalog"=>
            model_catalog_view(tool.manager,tool.provider,ctx;offset=get(params,"offset",0),limit=get(params,"limit",50)))
    elseif method in ("models/job","models/cancel_job")
        ctx = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        return owned_operation(tool.manager.operations,rpc_string(params,"job_id";max_bytes=128),ctx;cancel=method == "models/cancel_job")
    end
    args = Dict{String,Any}(key=>value for (key,value) in params if key != "session_id")
    validate_schema(args,tool_schema(tool))
    owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
    arguments = deepcopy(args)
    start_operation!(tool.manager.operations,owner;kind=String(args["action"]),metadata=Dict("source_id"=>catalog_source_id(tool.provider))) do context
        execute(tool,arguments,context)
    end
end
