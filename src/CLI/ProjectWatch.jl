function cli_watch_number(flags::AbstractDict,key::String,default::Real;integer=false)
    haskey(flags,key) || return default
    value=tryparse(integer ? Int : Float64,flags[key])
    value!==nothing && isfinite(value) || throw(ShenScopeError(:input,key*" requires a finite number"))
    value
end

function cli_watch_event(event::AgentEvent;json=false)
    if json
        render_event(stdout,event;json=true)
        return
    end
    payload=event.payload
    if event.kind==:project_watch_started
        println("Watching project changes",payload["automatic"] ? " with automatic indexing." : ". Index changes remain pending until refreshed.")
    elseif event.kind==:project_watch_changed
        changes=payload["changes"]
        println("Source changes: ",changes["created"]," created, ",changes["modified"]," modified, ",changes["deleted"]," deleted; ",changes["configuration"]," configuration changes.")
    elseif event.kind==:project_watch_updated
        println("Indexed revision ",payload["revision"]," · ",payload["delta"]["changed_count"]," changed file facts.")
    elseif event.kind==:project_watch_error
        println(stderr,"Index update failed; committed facts retained: ",payload["error"]["message"])
    elseif event.kind==:project_watch_stopped
        println(payload["phase"]=="failed" ? "Project watch failed: "*payload["error"]["message"] : "Project watch stopped.")
    end
    flush(stdout)
end

function cli_project_watch(positional::Vector{String},flags::AbstractDict,config::AbstractDict,state_dir::String)
    length(positional)==2 || throw(ShenScopeError(:input,"Use project watch without source path arguments"))
    options=ProjectWatchOptions(;automatic=get(flags,"--automatic",false),
        poll_seconds=cli_watch_number(flags,"--poll-seconds",1.0),quiet_seconds=cli_watch_number(flags,"--quiet-seconds",0.25),
        native_hints=!get(flags,"--no-native-hints",false),
        maximum_files=cli_watch_number(flags,"--watch-file-limit",10000;integer=true),
        maximum_bytes=cli_watch_number(flags,"--watch-byte-limit",32*1024*1024;integer=true))
    duration=cli_watch_number(flags,"--duration",0.0)
    duration>=0 || throw(ShenScopeError(:input,"Watch duration must be zero or positive"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    context=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,sandbox=sandbox_from_config(config),
        session_id=get(flags,"--session","cli-project-watch"),budget=BudgetLedger(limits_from_config(config)),
        approve=cli_approval,sink=e->cli_watch_event(e;json=get(flags,"--json",false)))
    manager=ProjectManager();watch=nothing
    try
        backend=project_backend!(manager,String(get(flags,"--backend","tree_sitter")))
        state=build!(backend,context)
        watch=start_project_watch(backend,state,context;options)
        deadline=duration==0 ? Inf : time_ns()/1e9+duration
        while !istaskdone(watch.task) && time_ns()/1e9<deadline
            sleep(0.05)
        end
        stop_project_watch!(watch)
        project_watch_status(watch)["phase"]=="failed" ? 1 : 0
    catch error
        error isa InterruptException || rethrow()
        0
    finally
        watch!==nothing && stop_project_watch!(watch)
        cleanup_projects!(manager)
    end
end
