const PROJECT_WATCH_METHODS=("project/watch_start","project/watch_status","project/watch_stop",
    "project/watch_refresh","project/watch_list")

function owned_project_watch(manager::ProjectManager,server::CoreServer,session::Session,id::String)
    lock(manager.mutex) do
        watch=get(manager.watches,id,nothing)
        watch===nothing && throw(ShenScopeError(:watch,"Project watcher not found"))
        watch.context.session_id==session.id && watch.context.root==server.root ||
            throw(ShenScopeError(:permission,"Project watcher belongs to another conversation"))
        watch
    end
end

function project_watch_rpc(server::CoreServer,method::String,params::AbstractDict)
    manager=server_project_tool(server).manager
    session=method=="project/watch_start" ? idle_session(server,params) : server_session(server,params)
    if method=="project/watch_start"
        allowed=("session_id","backend","automatic","poll_seconds","quiet_seconds","native_hints","maximum_files","maximum_bytes")
        all(key->key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown watcher start parameter"))
        name=rpc_string(params,"backend";default="tree_sitter",max_bytes=64)
        options=ProjectWatchOptions(;automatic=get(params,"automatic",false),poll_seconds=get(params,"poll_seconds",1.0),
            quiet_seconds=get(params,"quiet_seconds",0.25),native_hints=get(params,"native_hints",true),
            maximum_files=get(params,"maximum_files",10000),maximum_bytes=get(params,"maximum_bytes",32*1024*1024))
        owner=get(server.contexts,session.id,nothing)
        (owner===nothing || iscancelled(owner.cancellation)) && (owner=server_context(server,session.id))
        watch=lock(manager.mutex) do
            any(job->job["status"]=="running",values(manager.jobs)) &&
                throw(ShenScopeError(:watch_busy,"Finish project jobs before starting a watcher"))
            any(w->w.context.root==server.root && w.state.backend==name && watch_live(w),values(manager.watches)) &&
                throw(ShenScopeError(:watch_busy,"This project backend already has an active watcher"))
            count(watch_live,values(manager.watches))<16 || throw(ShenScopeError(:watch_capacity,"Active project watcher limit reached"))
            if length(manager.watches)>=32
                completed=sort!([w for w in values(manager.watches) if !watch_live(w)];by=w->(w.started_at,w.id))
                isempty(completed) && throw(ShenScopeError(:watch_capacity,"Retained watcher limit reached"))
                delete!(manager.watches,first(completed).id)
            end
            key=digest(server.root)*":"*name
            key in manager.mutations && throw(ShenScopeError(:watch_busy,"A tool operation currently owns this project index"))
            state=get(manager.states,key,nothing)
            state===nothing && throw(ShenScopeError(:watch,"Build or reload this backend index before watching"))
            backend=project_backend!(manager,name)
            value=ProjectWatch(backend,state,owner;options)
            value.context.approve=request->server_approval(server,session.id,value.context.cancellation,request)
            manager.watches[value.id]=value
            value
        end
        watch.task=@async with_context(()->project_watch_loop!(watch),watch.context)
        return project_watch_status(watch)
    elseif method=="project/watch_list"
        all(key->key=="session_id",keys(params)) || throw(RPCFault(-32602,"Unknown watcher list parameter"))
        watches=lock(manager.mutex) do
            sort!([w for w in values(manager.watches) if w.context.session_id==session.id && w.context.root==server.root];
                by=w->(w.started_at,w.id))
        end
        return [project_watch_status(w;limit=10) for w in watches]
    end
    allowed=method=="project/watch_status" ? ("session_id","watch_id","limit","offset") : ("session_id","watch_id")
    all(key->key in allowed,keys(params)) || throw(RPCFault(-32602,"Unknown watcher parameter"))
    watch=owned_project_watch(manager,server,session,rpc_string(params,"watch_id";max_bytes=128))
    method=="project/watch_status" && return project_watch_status(watch;offset=get(params,"offset",0),limit=get(params,"limit",100))
    method=="project/watch_stop" && return stop_project_watch!(watch;wait_for_completion=false)
    if method=="project/watch_refresh"
        idle_session(server,params)
        return refresh_project_watch!(watch)
    end
    throw(RPCFault(-32601,"Project watcher method not found"))
end
