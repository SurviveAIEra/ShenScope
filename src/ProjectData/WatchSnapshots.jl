function watch_committed_configuration(::AbstractProjectDataBackend,state::ProjectState)
    Dict{String,ProjectWatchStamp}()
end
function watch_committed_configuration(backend::TypeScriptSemanticBackend,state::ProjectState)
    compiler=get(state.metadata,"compiler",Dict())
    files=Dict{String,ProjectWatchStamp}(String(source["path"])=>ProjectWatchStamp(:configuration,String(source["sha256"]),0)
        for source in get(compiler,"configuration_sources",Any[]))
    entry=String(get(compiler,"configuration_entry",backend.config_path))
    get!(files,entry,ProjectWatchStamp(:configuration,nothing,0))
    files
end
function watch_committed_snapshot(backend::AbstractProjectDataBackend,state::ProjectState)
    lock(state.mutex) do
        files=Dict{String,ProjectWatchStamp}(path=>ProjectWatchStamp(:source,facts.sha256,0) for (path,facts) in state.files)
        merge!(files,watch_committed_configuration(backend,state))
        snapshot=ProjectWatchSnapshot(files)
        inventory=get(get(state.metadata,"compiler",Dict()),"observed_inputs_sha256",nothing)
        if inventory!==nothing
            inventory isa AbstractString && occursin(r"^[a-f0-9]{64}$",inventory) ||
                throw(ShenScopeError(:storage,"Invalid committed compiler input inventory"))
            return ProjectWatchSnapshot(files,String(inventory),snapshot.bytes,nothing)
        end
        snapshot
    end
end

function compiler_watch_inventory(documents::AbstractVector,config::CompilerConfig)
    files=Dict{String,ProjectWatchStamp}(String(document["path"])=>ProjectWatchStamp(:source,String(document["sha256"]),0)
        for document in documents)
    for source in config.sources
        files[String(source["path"])]=ProjectWatchStamp(:configuration,String(source["sha256"]),0)
    end
    get!(files,config.entry,ProjectWatchStamp(:configuration,nothing,0))
    ProjectWatchSnapshot(files).sha256
end

function watch_read_checkpoint(watch::ProjectWatch)
    ctx=watch.context
    project_storage_checkpoint(ctx)
    permission_decision(ctx.permissions,PermissionRequest("watch-read",:read,"project.watch",ctx.root,
        "Observe project source changes"))!=Deny || throw(ShenScopeError(:permission,"Project watching read permission was revoked"))
    realpath(ctx.root)==ctx.root || throw(ShenScopeError(:permission,"Watched workspace identity changed"))
end

function watch_read_stamp(watch::ProjectWatch,path::String,role::Symbol;maximum=8*1024*1024)
    watch_read_checkpoint(watch)
    absolute=workspace_path(watch.context.root,path)
    islink(absolute) && throw(ShenScopeError(:permission,"Watched inputs may not follow symlinks"))
    ispath(absolute) && !isfile(absolute) && throw(ShenScopeError(:watch,"Watched input must be a regular file"))
    if !isfile(absolute)
        return ProjectWatchStamp(role,nothing,0),nothing
    end
    text=read_scoped_text(watch.context,watch.context.root,absolute,maximum;authorized=true,
        tool="project.watch",size_error=:watch_capacity,encoding_error=:watch_encoding)
    stamp=ProjectWatchStamp(role,digest(text),ncodeunits(text))
    watch_read_checkpoint(watch)
    stamp,text
end

function watch_configuration_snapshot(::AbstractProjectDataBackend,watch::ProjectWatch)
    Dict{String,ProjectWatchStamp}(),nothing
end
function watch_configuration_snapshot(backend::TypeScriptSemanticBackend,watch::ProjectWatch)
    ctx=watch.context;files=Dict{String,ProjectWatchStamp}();failure=nothing
    queue=Tuple{String,Int}[(compiler_path(ctx,backend.config_path),1)]
    # Old dependency paths remain observable when an invalid entry prevents
    # resolving its new inheritance. Successful replay supplies the new scope.
    known=lock(watch.state.mutex) do
        collect(keys(watch_committed_configuration(backend,watch.state)))
    end
    while !isempty(queue)
        path,depth=popfirst!(queue)
        haskey(files,path) && continue
        depth<=8 && length(files)<32 || throw(ShenScopeError(:watch_capacity,"Watched compiler inheritance exceeds capacity"))
        stamp,text=watch_read_stamp(watch,path,:configuration;maximum=256*1024)
        files[path]=stamp
        text===nothing && continue
        try
            document=compiler_jsonc(text)
            parents=get(document,"extends",Any[])
            parents isa AbstractString && (parents=[parents])
            for parent in compiler_strings(parents;maximum=8,label="extends")
                (startswith(parent,".") || isabspath(parent)) ||
                    throw(ShenScopeError(:compiler_config,"Compiler package inheritance is unsupported"))
                endswith(lowercase(parent),".json") || (parent*=".json")
                relative=compiler_path(ctx,parent;base=dirname(joinpath(ctx.root,path)))
                push!(queue,(relative,depth+1))
            end
        catch error
            error isa ShenScopeError && error.code in (:permission,:cancelled,:budget) && rethrow()
            failure=error isa ShenScopeError ? first(error.message,4096) : "Invalid watched compiler configuration"
        end
    end
    if failure!==nothing
        for path in known
            haskey(files,path) && continue
            length(files)<32 || throw(ShenScopeError(:watch_capacity,"Watched compiler inheritance exceeds capacity"))
            files[path]=first(watch_read_stamp(watch,compiler_path(ctx,path),:configuration;maximum=256*1024))
        end
    end
    files,failure
end

function scan_project_watch(watch::ProjectWatch)
    watch_read_checkpoint(watch)
    options=watch.options;backend=watch.backend
    paths=project_paths(watch.context,backend_capabilities(backend);limit=options.maximum_files,
        checkpoint=()->watch_read_checkpoint(watch))
    files=Dict{String,ProjectWatchStamp}();total=0
    for path in paths
        stamp,_=watch_read_stamp(watch,path,:source)
        stamp.sha256===nothing && throw(ShenScopeError(:conflict,"Source disappeared during watcher scan"))
        total+=stamp.bytes
        total<=options.maximum_bytes || throw(ShenScopeError(:watch_capacity,"Watched source bytes exceed capacity"))
        files[path]=stamp
    end
    configuration,failure=watch_configuration_snapshot(backend,watch)
    merge!(files,configuration)
    snapshot=ProjectWatchSnapshot(files;configuration_error=failure)
    snapshot.bytes<=options.maximum_bytes || throw(ShenScopeError(:watch_capacity,"Watched input bytes exceed capacity"))
    watch_read_checkpoint(watch)
    snapshot
end

function watch_snapshot_changes(before::ProjectWatchSnapshot,after::ProjectWatchSnapshot)
    created=String[];modified=String[];deleted=String[];configuration=String[]
    for path in sort!(collect(union(keys(before.files),keys(after.files))))
        old=get(before.files,path,nothing);new=get(after.files,path,nothing)
        old==new && continue
        if (old!==nothing && old.role==:configuration) || (new!==nothing && new.role==:configuration)
            push!(configuration,path)
        elseif old===nothing
            push!(created,path)
        elseif new===nothing
            push!(deleted,path)
        else
            push!(modified,path)
        end
    end
    inventory_changed=before.sha256!=after.sha256 && all(isempty,(created,modified,deleted,configuration))
    ProjectWatchChanges(created,modified,deleted,configuration,inventory_changed)
end
