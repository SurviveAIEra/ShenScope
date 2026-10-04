function memory_namespace(value)
    value isa AbstractString && isvalid(value) &&
        occursin(r"^[a-z][a-z0-9_.-]{0,63}$",value) ||
        throw(ShenScopeError(:memory,"Namespace must be a bounded lowercase identifier"))
    String(value)
end

function memory_owner(ctx::RuntimeContext,scope::Symbol)
    scope in (:workspace,:session,:user) || throw(ShenScopeError(:memory,"Unknown memory scope"))
    scope==:workspace ? digest(ctx.root) : scope==:session ? valid_id(ctx.session_id) : "local-user"
end

function memory_store(ctx::RuntimeContext,scope::Symbol=:workspace;namespace=MEMORY_DEFAULT_NAMESPACE)
    namespace=memory_namespace(namespace);owner=memory_owner(ctx,scope)
    base=joinpath(ctx.state_dir,"memory",String(scope),owner)
    path=namespace==MEMORY_DEFAULT_NAMESPACE ? base*".jsonl" :
        joinpath(base*".namespaces",digest(namespace)*".jsonl")
    versions=namespace==MEMORY_DEFAULT_NAMESPACE ? VersionedStore(path) :
        VersionedStore(path;max_entries=256,max_log_bytes=8*1024^2)
    MemoryStore(versions,scope,owner,namespace,scope==:user ? nothing : digest(ctx.root))
end

function memory_registry(ctx::RuntimeContext,scope::Symbol)
    owner=memory_owner(ctx,scope)
    VersionedStore(joinpath(ctx.state_dir,"memory",String(scope),owner*".namespaces.jsonl");
        max_entries=MAX_MEMORY_NAMESPACES-1,max_log_bytes=64*1024,history_limit=1)
end

function memory_path_guard(path::String,ctx::RuntimeContext)
    root=normpath(abspath(ctx.state_dir));target=normpath(abspath(path))
    relative=relpath(target,root)
    parts=splitpath(relative)
    (!isempty(parts) && first(parts)!=".." && !isabspath(relative)) ||
        throw(ShenScopeError(:permission,"Memory storage escapes the configured state directory"))
    current=root
    existing=root
    while !ispath(existing) && !islink(existing)
        parent=dirname(existing);parent==existing && break;existing=parent
    end
    ispath(existing) && realpath(existing)!=existing &&
        throw(ShenScopeError(:permission,"Memory state directory is not canonical"))
    islink(current) && throw(ShenScopeError(:permission,"Memory state directory symlinks are not supported"))
    for part in splitpath(relative)
        current=joinpath(current,part)
        islink(current) && throw(ShenScopeError(:permission,"Memory storage symlinks are not supported"))
    end
    if ispath(target)
        isfile(target) || throw(ShenScopeError(:storage,"Memory journal must be a regular file"))
        realpath(target)==target || throw(ShenScopeError(:permission,"Memory storage path is not canonical"))
    end
    nothing
end

function memory_store_guard(versions::VersionedStore,ctx::RuntimeContext)
    for suffix in ("",".lock",".transaction.lock",".admission.lock")
        memory_path_guard(versions.journal.path*suffix,ctx)
    end
    isfile(versions.journal.path) && filesize(versions.journal.path)>versions.max_log_bytes &&
        throw(ShenScopeError(:capacity,"Memory journal exceeds its configured capacity"))
    nothing
end

function check_memory_scope(store::MemoryStore,ctx::RuntimeContext)
    expected=memory_store(ctx,store.scope;namespace=store.namespace)
    store.owner==expected.owner && store.workspace_sha256==expected.workspace_sha256 &&
        store.versions.journal.path==expected.versions.journal.path ||
        throw(ShenScopeError(:permission,"Memory belongs to another runtime scope or namespace"))
    memory_store_guard(store.versions,ctx)
    nothing
end

memory_target(store::MemoryStore,key::Union{Nothing,AbstractString}=nothing) =
    String(store.scope)*":"*store.namespace*(key===nothing ? "" : ":"*object_key(key))

function memory_checkpoint(ctx::RuntimeContext,category::Symbol,tool::String,target::String;cooperate=true)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    permission_decision(ctx.permissions,PermissionRequest("memory-check",category,tool,target,"Memory operation"))==Deny &&
        throw(ShenScopeError(:permission,"Memory operation is now denied"))
    cooperate && yield()
    nothing
end

function memory_registry_records(ctx::RuntimeContext,scope::Symbol;category=:read)
    registry=memory_registry(ctx,scope);memory_store_guard(registry,ctx)
    isfile(registry.journal.path) || return Dict{String,Any}[]
    target=String(scope)
    checkpoint=()->memory_checkpoint(ctx,category,"memory.namespaces",target)
    store_lock(registry.journal.path*".transaction";checkpoint) do
        memory_store_guard(registry,ctx);latest=Dict{String,Dict{String,Any}}()
        walk=walk_journal(registry.journal;maximum_bytes=registry.max_log_bytes,checkpoint) do record,_,_
            get(record,"kind",nothing)=="versioned" && get(record,"deleted",nothing)===false &&
                get(record,"key",nothing) isa AbstractString && get(record,"value",nothing) isa AbstractDict ||
                throw(ShenScopeError(:storage,"Memory namespace event is invalid"))
            name=memory_namespace(record["key"]);value=record["value"]
            name!=MEMORY_DEFAULT_NAMESPACE || throw(ShenScopeError(:storage,"Default memory namespace cannot be registered"))
            memory_version(get(record,"version",nothing))
            prior=get(latest,name,nothing)
            prior===nothing || record["version"]>prior["version"] ||
                throw(ShenScopeError(:storage,"Memory namespace versions are not increasing"))
            Set(keys(value))==Set(["schema","name","scope","owner","workspace_sha256","name_sha256"]) &&
                get(value,"schema",nothing)===1 && value["name"]==name && value["scope"]==String(scope) &&
                value["owner"]==memory_owner(ctx,scope) &&
                value["workspace_sha256"]==(scope==:user ? nothing : digest(ctx.root)) &&
                value["name_sha256"]==digest(name) && get(record,"sha256",nothing)==digest(canonical(value)) ||
                throw(ShenScopeError(:storage,"Memory namespace declaration is invalid"))
            memory_timestamp(get(record,"created",nothing));memory_timestamp(get(record,"updated",nothing))
            latest[name]=record
            length(latest)<=registry.max_entries || throw(ShenScopeError(:capacity,"Memory namespace limit exceeded"))
        end
        walk.torn_bytes==0 || throw(ShenScopeError(:storage,"Memory namespace registry has an uncommitted tail"))
        memory_store_guard(registry,ctx);checkpoint()
        [latest[name] for name in sort!(collect(keys(latest)))]
    end
end

function memory_namespace_registered(store::MemoryStore,ctx::RuntimeContext;category=:read)
    store.namespace==MEMORY_DEFAULT_NAMESPACE && return true
    any(record->record["key"]==store.namespace,memory_registry_records(ctx,store.scope;category))
end

function register_memory_namespace!(store::MemoryStore,ctx::RuntimeContext)
    store.namespace==MEMORY_DEFAULT_NAMESPACE && return nothing
    registry=memory_registry(ctx,store.scope);memory_store_guard(registry,ctx)
    store_lock(registry.journal.path*".admission";
            checkpoint=()->memory_checkpoint(ctx,:persistence,"memory.namespace",memory_target(store))) do
        records=memory_registry_records(ctx,store.scope;category=:persistence)
        any(record->record["key"]==store.namespace,records) && return nothing
        length(records)<MAX_MEMORY_NAMESPACES-1 || throw(ShenScopeError(:capacity,"Memory namespace limit reached"))
        memory_store_guard(registry,ctx)
        version_put!(registry,store.namespace,Dict("schema"=>1,"name"=>store.namespace,
            "scope"=>String(store.scope),"owner"=>store.owner,"workspace_sha256"=>store.workspace_sha256,
            "name_sha256"=>digest(store.namespace));expected_version=0)
        nothing
    end
end

function memory_namespaces(ctx::RuntimeContext;scope::Symbol=:workspace)
    owner=memory_owner(ctx,scope);target=String(scope)
    authorize!(ctx,:read,"memory.namespaces",target)
    memory_checkpoint(ctx,:read,"memory.namespaces",target)
    records=memory_registry_records(ctx,scope)
    names=sort!(vcat([MEMORY_DEFAULT_NAMESPACE],[record["key"] for record in records]))
    memory_checkpoint(ctx,:read,"memory.namespaces",target)
    Dict("scope"=>String(scope),"owner"=>owner,"namespaces"=>names,
        "limit"=>MAX_MEMORY_NAMESPACES,"default_journal_compatible"=>true)
end
