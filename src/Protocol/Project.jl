function server_project_tool(server::CoreServer)
    only(tool for tool in server.tools if tool isa ProjectTool)
end
function project_job_view(job::AbstractDict)
    Dict(key=>job[key] for key in ("id","status","session_id","backend","action","result","error") if haskey(job,key))
end
function project_rpc(server::CoreServer,method::String,params::AbstractDict)
    tool=server_project_tool(server);manager=tool.manager
    if method=="project/backends"
        return [capability_dict(backend_capabilities(backend)) for backend in (GoASTBackend(),TreeSitterBackend(),CodeGraphBackend())]
    elseif method=="project/start"
        session=server_session(server,params)
        args=Dict{String,Any}(key=>value for (key,value) in params if key!="session_id")
        validate_schema(args,tool_schema(tool));args["action"] in ("build","update","impact","test_selection","architecture") ||
            throw(RPCFault(-32602,"Use project/query for read operations"))
        name=get(args,"backend","tree_sitter")
        context=server_context(server,session.id);id=string(uuid4())
        job=Dict{String,Any}("id"=>id,"status"=>"running","session_id"=>session.id,"backend"=>name,"action"=>args["action"],"context"=>context)
        lock(manager.mutex) do
            any(j->j["status"]=="running",values(manager.jobs)) && throw(ShenScopeError(:runtime,"A project job is already running"))
            if length(manager.jobs)>=64
                done=sort!([key for (key,j) in manager.jobs if j["status"]!="running"])
                isempty(done) && throw(ShenScopeError(:runtime,"Project job limit reached"));delete!(manager.jobs,first(done))
            end
            manager.jobs[id]=job
        end
        job["task"]=@async begin
            try
                result=with_context(()->execute(tool,args,context),context)
                lock(manager.mutex) do;job["result"]=result;job["status"]="complete";end
                emit!(context,:project_completed,Dict("job_id"=>id,"action"=>args["action"],"backend"=>name,"result"=>result))
            catch error
                message=error isa ShenScopeError ? error.message : "Project operation failed"
                lock(manager.mutex) do;job["status"]="failed";job["error"]=message;end
                emit!(context,:project_failed,Dict("job_id"=>id,"message"=>message))
            end
        end
        return Dict("job_id"=>id,"started"=>true)
    elseif method in ("project/job","project/cancel")
        id=rpc_string(params,"job_id";max_bytes=128)
        return lock(manager.mutex) do
            job=get(manager.jobs,id,nothing);job===nothing && throw(ShenScopeError(:graph,"Project job not found"))
            method=="project/cancel" && cancel!(job["context"].cancellation)
            project_job_view(job)
        end
    elseif method=="project/query"
        name=rpc_string(params,"backend";default="tree_sitter",max_bytes=64)
        policy=permissions_from_config(server.config)
        if haskey(params,"session_id")
            session=server_session(server,params)
            prior=get(server.contexts,session.id,nothing)
            prior!==nothing && (policy=prior.permissions)
        end
        permission_decision(policy,PermissionRequest("query",:read,"project.query",server.root,"Read indexed project facts"))==Allow ||
            throw(ShenScopeError(:permission,"Reading project facts requires approval; start indexing and choose the appropriate permission scope"))
        state=lock(manager.mutex) do
            any(j->j["status"]=="running",values(manager.jobs)) && throw(ShenScopeError(:runtime,"Project index is busy; wait for its completion event"))
            key=digest(server.root)*":"*name
            current=get(manager.states,key,nothing)
            if current===nothing
                backend=project_backend!(manager,name)
                context=RuntimeContext(server.root;state_dir=server.state_dir,permissions=policy)
                candidate=ProjectState(context,backend)
                if isfile(candidate.journal.path)
                    current=load_project(backend,context);manager.states[key]=current
                end
            end
            current
        end
        state===nothing && return Dict("indexed"=>false,"backend"=>name)
        action=rpc_string(params,"action";default="status",max_bytes=64)
        trylock(state.mutex) || throw(ShenScopeError(:runtime,"Project state is being updated"))
        try
            action=="status" && return merge(project_status(state),Dict("indexed"=>true))
            action=="search" && return graph_search(state,rpc_string(params,"query";default="",max_bytes=4096);
                limit=get(params,"limit",50),offset=get(params,"offset",0))
            throw(RPCFault(-32602,"Unknown project query"))
        finally
            unlock(state.mutex)
        end
    end
    throw(RPCFault(-32601,"Project method not found"))
end
