struct ProjectWatchOptions
    automatic::Bool
    poll_seconds::Float64
    quiet_seconds::Float64
    native_hints::Bool
    maximum_files::Int
    maximum_bytes::Int
    function ProjectWatchOptions(;automatic=false,poll_seconds=1.0,quiet_seconds=0.25,
            native_hints=true,maximum_files=10000,maximum_bytes=32*1024*1024)
        automatic isa Bool && native_hints isa Bool ||
            throw(ShenScopeError(:watch,"Watch switches must be Boolean"))
        for (value,minimum,maximum,label) in ((poll_seconds,0.05,3600.0,"poll"),(quiet_seconds,0.01,30.0,"quiet"))
            value isa Real && !(value isa Bool) && isfinite(value) && minimum<=value<=maximum ||
                throw(ShenScopeError(:watch,"Invalid watcher "*label*" interval"))
        end
        maximum_files isa Integer && !(maximum_files isa Bool) && 1<=maximum_files<=10000 ||
            throw(ShenScopeError(:watch,"Invalid watcher file capacity"))
        maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 1<=maximum_bytes<=32*1024*1024 ||
            throw(ShenScopeError(:watch,"Invalid watcher byte capacity"))
        new(automatic,Float64(poll_seconds),Float64(quiet_seconds),native_hints,Int(maximum_files),Int(maximum_bytes))
    end
end

struct ProjectWatchStamp
    role::Symbol
    sha256::Union{Nothing,String}
    bytes::Int
end
Base.:(==)(a::ProjectWatchStamp,b::ProjectWatchStamp)=a.role==b.role && a.sha256==b.sha256

struct ProjectWatchSnapshot
    files::Dict{String,ProjectWatchStamp}
    sha256::String
    bytes::Int
    configuration_error::Union{Nothing,String}
end
function ProjectWatchSnapshot(files::Dict{String,ProjectWatchStamp};configuration_error=nothing)
    leaves=[[path,String(files[path].role),files[path].sha256] for path in sort!(collect(keys(files)))]
    ProjectWatchSnapshot(files,digest(canonical(leaves)),sum(stamp.bytes for stamp in values(files);init=0),configuration_error)
end

struct ProjectWatchChanges
    created::Vector{String}
    modified::Vector{String}
    deleted::Vector{String}
    configuration::Vector{String}
    inventory_changed::Bool
end
ProjectWatchChanges(created,modified,deleted,configuration)=ProjectWatchChanges(created,modified,deleted,configuration,false)
ProjectWatchChanges()=ProjectWatchChanges(String[],String[],String[],String[])
Base.isempty(changes::ProjectWatchChanges)=!changes.inventory_changed && all(isempty,(changes.created,changes.modified,changes.deleted,changes.configuration))
watch_source_paths(changes::ProjectWatchChanges)=sort!(unique(vcat(changes.created,changes.modified,changes.deleted)))

mutable struct ProjectWatch
    id::String
    backend::AbstractProjectDataBackend
    state::ProjectState
    context::RuntimeContext
    options::ProjectWatchOptions
    applied::ProjectWatchSnapshot
    observed::Union{Nothing,ProjectWatchSnapshot}
    dirty::ProjectWatchChanges
    changed_at::Float64
    phase::Symbol
    started_at::String
    checked_at::Union{Nothing,String}
    scans::Int
    updates::Int
    failed_updates::Int
    native_events::Int
    last_error::Union{Nothing,Dict{String,Any}}
    failed_fingerprint::Union{Nothing,String}
    published_fingerprint::Union{Nothing,String}
    refresh_requested::Bool
    signal::Channel{Nothing}
    signal_mutex::ReentrantLock
    mutex::ReentrantLock
    task::Union{Nothing,Task}
    timer::Union{Nothing,Timer}
    settle_timer::Union{Nothing,Timer}
    monitor::Union{Nothing,FileWatching.FolderMonitor}
    monitor_task::Union{Nothing,Task}
    native_error::Union{Nothing,String}
end

function ProjectWatch(backend::AbstractProjectDataBackend,state::ProjectState,ctx::RuntimeContext;
        options=ProjectWatchOptions())
    ctx.root==state.root && backend_capabilities(backend).name==state.backend ||
        throw(ShenScopeError(:watch,"Watcher index/backend/workspace mismatch"))
    project_journal_scope(state,ctx)
    context=child_context(ctx)
    ProjectWatch(string(uuid4()),backend,state,context,options,watch_committed_snapshot(backend,state),
        nothing,ProjectWatchChanges(),0.0,:starting,utcstamp(),nothing,0,0,0,0,nothing,nothing,nothing,false,
        Channel{Nothing}(1),ReentrantLock(),ReentrantLock(),nothing,nothing,nothing,nothing,nothing,nothing)
end

function watch_error(error)
    error isa ShenScopeError ? Dict{String,Any}("code"=>String(error.code),"message"=>first(error.message,4096)) :
        Dict{String,Any}("code"=>"watch","message"=>"Project watcher operation failed")
end
watch_live(watch::ProjectWatch)=lock(watch.mutex) do
    watch.phase in (:starting,:watching,:pending,:dirty,:updating,:stopping) ||
        watch.task!==nothing && !istaskdone(watch.task)
end

function watch_changes_view(changes::ProjectWatchChanges;offset=0,limit=100)
    offset isa Integer && !(offset isa Bool) && 0<=offset<=20000 &&
        limit isa Integer && !(limit isa Bool) && 1<=limit<=100 ||
        throw(ShenScopeError(:watch,"Invalid watcher change page"))
    entries=sort!(vcat([Dict("path"=>path,"kind"=>kind) for (kind,paths) in
        (("created",changes.created),("modified",changes.modified),("deleted",changes.deleted),("configuration",changes.configuration))
        for path in paths]);by=value->(value["path"],value["kind"]))
    Dict("created"=>length(changes.created),"modified"=>length(changes.modified),"deleted"=>length(changes.deleted),
        "configuration"=>length(changes.configuration),"inventory_changed"=>changes.inventory_changed,
        "total"=>length(entries)+Int(changes.inventory_changed),"offset"=>offset,
        "entries"=>entries[min(offset+1,length(entries)+1):min(offset+limit,length(entries))],
        "has_more"=>offset+limit<length(entries))
end

function project_watch_status(watch::ProjectWatch;offset=0,limit=100)
    lock(watch.mutex) do
        Dict("id"=>watch.id,"session_id"=>watch.context.session_id,"backend"=>watch.state.backend,
            "phase"=>String(watch.phase),"automatic"=>watch.options.automatic,
            "poll_seconds"=>watch.options.poll_seconds,"quiet_seconds"=>watch.options.quiet_seconds,
            "native_hints"=>watch.options.native_hints,"native_events"=>watch.native_events,"native_error"=>watch.native_error,
            "started_at"=>watch.started_at,"checked_at"=>watch.checked_at,"scans"=>watch.scans,
            "updates"=>watch.updates,"failed_updates"=>watch.failed_updates,"error"=>deepcopy(watch.last_error),
            "configuration_error"=>watch.observed===nothing ? nothing : watch.observed.configuration_error,
            "changes"=>watch_changes_view(watch.dirty;offset,limit),"applied_sha256"=>watch.applied.sha256,
            "observed_sha256"=>watch.observed===nothing ? nothing : watch.observed.sha256,
            "refresh_requested"=>watch.refresh_requested)
    end
end
