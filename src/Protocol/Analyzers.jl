server_analyzers_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa AnalyzersTool)

function analyzer_catalog(tool::AnalyzersTool,ctx::RuntimeContext;project_offset=0,user_offset=0)
    entries = analyzer_list(tool.manager,ctx;limit=100)
    states = lock(tool.projects.mutex) do
        [state for state in values(tool.projects.states) if state.root == ctx.root]
    end
    backends = [lock(state.mutex) do
        Dict("backend"=>state.backend,"revision"=>state.revision,"symbols"=>length(state.symbols),
            "relations"=>length(state.relations),"coverage"=>capability_dict(state.capabilities))
        end for state in states]
    sort!(backends;by=value -> value["backend"])
    archive = analyzer_archive(ctx)
    active = Dict(name=>analyzer_active(archive,name,ctx) for name in
        unique(entry["definition"]["name"] for entry in entries["analyzers"]))
    jobs = lock(tool.manager.mutex) do
        [Dict("job_id"=>job.id,"action"=>job.action,"status"=>String(job.status)) for job in values(tool.manager.jobs)
            if job.context.session_id == ctx.session_id && job.context.root == ctx.root && job.status == :running]
    end
    Dict("platform"=>analyzer_platform_status(),"session"=>entries,"project_backends"=>backends,
        "jobs"=>jobs,"requirements"=>["definitions","relations"],
        "project_active"=>active,
        "project_archive"=>analyzer_archive_list(ctx;scope=:project,offset=project_offset,limit=50),
        "user_archive"=>analyzer_archive_list(ctx;scope=:user,offset=user_offset,limit=50))
end

function analyzers_rpc(server::CoreServer,method::String,params::AbstractDict)
    method in ("analyzers/query","analyzers/start","analyzers/job","analyzers/cancel_job") ||
        throw(RPCFault(-32601,"Unknown analyzer method"))
    if method != "analyzers/start"
        allowed = method == "analyzers/query" ? ("session_id","project_offset","user_offset") : ("session_id","job_id")
        all(key -> key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown analyzer parameter"))
    end
    tool = server_analyzers_tool(server)
    session = server_session(server,params)
    prior = get(server.contexts,session.id,nothing)
    if method == "analyzers/query"
        policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
        permission_decision(policy,PermissionRequest("analyzer-query",:read,"analysis.catalog",server.root,"Read analyzer catalog")) == Allow ||
            throw(ShenScopeError(:permission,"Use analyzers/start for permissioned catalog reads"))
        context = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir,permissions=policy)
        return analyzer_catalog(tool,context;project_offset=get(params,"project_offset",0),user_offset=get(params,"user_offset",0))
    elseif method in ("analyzers/job","analyzers/cancel_job")
        context = RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir)
        return analyzer_job(tool.manager,rpc_string(params,"job_id";max_bytes=128),context;cancel=method == "analyzers/cancel_job")
    elseif method == "analyzers/start"
        args = Dict{String,Any}(key=>value for (key,value) in params if key != "session_id")
        validate_schema(args,tool_schema(tool))
        context_jobs_running(server_context_tool(server).manager;session_id=session.id) &&
            throw(ShenScopeError(:runtime,"Finish this conversation's context operation before starting an analyzer operation"))
        args["action"] in ("register","select","remove","restore","promote","rollback") && haskey(server.runs,session.id) &&
            throw(ShenScopeError(:runtime,"Change analyzer versions between agent runs"))
        owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server,session.id) : prior
        return start_analyzer_job!(tool,args,owner)
    end
    throw(RPCFault(-32601,"Unknown analyzer method"))
end
