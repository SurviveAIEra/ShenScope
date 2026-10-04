function memory_timestamp(value;argument=false)
    code=argument ? :arguments : :storage
    value isa AbstractString && occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$",value) ||
        throw(ShenScopeError(code,"Memory timestamp must be a UTC timestamp with milliseconds"))
    try
        DateTime(chop(String(value);tail=1))
    catch
        throw(ShenScopeError(code,"Memory timestamp is invalid"))
    end
    String(value)
end

function memory_version(value;allow_zero=false)
    value isa Integer && !(value isa Bool) && (allow_zero ? 0 : 1)<=value<=9007199254740991 ||
        throw(ShenScopeError(:memory,"Memory version must be a nonnegative safe integer"))
    Int(value)
end

function validate_memory_record(store::MemoryStore,record::AbstractDict)
    get(record,"kind",nothing)=="versioned" || throw(ShenScopeError(:storage,"Unknown memory record kind"))
    key=get(record,"key",nothing)
    key isa AbstractString || throw(ShenScopeError(:storage,"Memory record key is invalid"))
    object_key(key);memory_version(get(record,"version",nothing))
    deleted=get(record,"deleted",nothing)
    deleted isa Bool || throw(ShenScopeError(:storage,"Memory deletion marker is invalid"))
    value=get(record,"value",nothing)
    value isa AbstractDict || throw(ShenScopeError(:storage,"Memory record value is invalid"))
    get(value,"scope",nothing)==String(store.scope) && get(value,"owner",nothing)==store.owner &&
        get(value,"namespace",MEMORY_DEFAULT_NAMESPACE)==store.namespace ||
        throw(ShenScopeError(:storage,"Memory record scope or namespace mismatch"))
    workspace=get(value,"workspace_sha256",store.scope==:workspace ? store.owner : nothing)
    workspace==store.workspace_sha256 || throw(ShenScopeError(:permission,"Memory record belongs to another workspace or lacks session ownership proof"))
    encoded=bounded_canonical_json(value;maximum=128*1024)
    get(record,"sha256",nothing)==digest(encoded) || throw(ShenScopeError(:storage,"Memory value checksum mismatch"))
    created=memory_timestamp(get(record,"created",nothing))
    updated=memory_timestamp(get(record,"updated",nothing))
    created<=updated || throw(ShenScopeError(:storage,"Memory update precedes creation"))
    if !deleted
        allowed=Set(["title","content","tags","source","scope","owner","namespace",
            "content_sha256","expires","source_reference","provenance_verified","origin_session_id","workspace_sha256"])
        all(name->name in allowed,keys(value)) || throw(ShenScopeError(:storage,"Unknown memory metadata field"))
        content=get(value,"content",nothing);title=get(value,"title",nothing);tags=get(value,"tags",nothing)
        content isa AbstractString && isvalid(content) && ncodeunits(content)<=65536 &&
            title isa AbstractString && isvalid(title) && ncodeunits(title)<=512 &&
            tags isa AbstractVector && length(tags)<=32 &&
            all(tag->tag isa AbstractString && isvalid(tag) && !isempty(strip(tag)) && ncodeunits(tag)<=128,tags) ||
            throw(ShenScopeError(:storage,"Memory content or metadata is invalid"))
        get(value,"content_sha256",nothing)==digest(content) || throw(ShenScopeError(:storage,"Memory content checksum mismatch"))
        get(value,"source",nothing) in ("user","agent","tool","import") ||
            throw(ShenScopeError(:storage,"Memory provenance source is invalid"))
        reference=get(value,"source_reference","")
        reference isa AbstractString && isvalid(reference) && ncodeunits(reference)<=512 ||
            throw(ShenScopeError(:storage,"Memory source reference is invalid"))
        get(value,"provenance_verified",false)===false ||
            throw(ShenScopeError(:storage,"Memory cannot claim verified provenance"))
        origin=get(value,"origin_session_id",nothing)
        origin===nothing || origin isa AbstractString && isvalid(origin) && ncodeunits(origin)<=128 ||
            throw(ShenScopeError(:storage,"Memory origin session is invalid"))
        expires=get(value,"expires",nothing)
        expires===nothing || expires isa Real && !(expires isa Bool) && isfinite(expires) && expires>=0 ||
            throw(ShenScopeError(:storage,"Memory expiry is invalid"))
    else
        all(name->name in ("scope","owner","namespace","workspace_sha256"),keys(value)) ||
            throw(ShenScopeError(:storage,"Unexpected metadata on a memory deletion marker"))
    end
    nothing
end

function memory_records(store::MemoryStore,ctx::RuntimeContext;tool="memory.read",authorized=false,
        category=:read,require_namespace=true)
    check_memory_scope(store,ctx);target=memory_target(store)
    category in (:read,:persistence) || throw(ArgumentError("Invalid memory storage category"))
    authorized || authorize!(ctx,:read,tool,target)
    memory_checkpoint(ctx,category,tool,target)
    (!require_namespace || memory_namespace_registered(store,ctx;category)) && isfile(store.versions.journal.path) ||
        return Dict{String,Any}[]
    store_lock(store.versions.journal.path*".transaction";
            checkpoint=()->memory_checkpoint(ctx,category,tool,target)) do
        memory_store_guard(store.versions,ctx)
        latest=Dict{String,Dict{String,Any}}()
        count=0
        walk=walk_journal(store.versions.journal;maximum_bytes=store.versions.max_log_bytes,
                checkpoint=()->memory_checkpoint(ctx,category,tool,target)) do record,_,_
            validate_memory_record(store,record);key=record["key"]
            prior=get(latest,key,nothing)
            prior===nothing || record["version"]>prior["version"] ||
                throw(ShenScopeError(:storage,"Memory object versions are not increasing"))
            latest[key]=record;count+=1
            length(latest)<=store.versions.max_entries &&
                count<=store.versions.max_entries*store.versions.history_limit ||
                throw(ShenScopeError(:capacity,"Memory journal exceeds its declared history capacity"))
        end
        walk.torn_bytes==0 || throw(ShenScopeError(:storage,"Memory journal has an uncommitted tail"))
        memory_store_guard(store.versions,ctx)
        memory_checkpoint(ctx,category,tool,target)
        [latest[key] for key in sort!(collect(keys(latest)))]
    end
end

function memory_scope_id(store::MemoryStore,ctx::RuntimeContext)
    digest(canonical([ctx.root,ctx.state_dir,String(store.scope),store.owner,store.namespace]))
end

function memory_snapshot(store::MemoryStore,ctx::RuntimeContext;tool="memory.retrieve",maximum_bytes=MAX_MEMORY_SNAPSHOT_BYTES,
        authorized=false)
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 1024<=maximum_bytes<=MAX_MEMORY_SNAPSHOT_BYTES ||
        throw(ShenScopeError(:arguments,"Invalid memory snapshot capacity"))
    records=memory_records(store,ctx;tool,authorized)
    scope_id=memory_scope_id(store,ctx)
    identity=[Dict("key"=>r["key"],"version"=>r["version"],"sha256"=>r["sha256"],
        "created"=>r["created"],"updated"=>r["updated"],"deleted"=>r["deleted"]) for r in records]
    id=digest(canonical(Dict("schema"=>1,"scope"=>scope_id,"records"=>identity)))
    documents=MemoryDocument[];bytes=0;omitted=0
    for record in records
        memory_checkpoint(ctx,:read,tool,memory_target(store))
        size=ncodeunits(canonical(record))
        if bytes+size>maximum_bytes
            omitted+=1;continue
        end
        bytes+=size
        push!(documents,MemoryDocument(record["key"],Int(record["version"]),record["sha256"],
            get(record["value"],"content_sha256",nothing),Dict{String,Any}(record["value"]),
            record["created"],record["updated"],record["deleted"]))
    end
    MemorySnapshot(store,id,scope_id,documents,time(),bytes,length(records),omitted)
end

function memory_snapshot_current!(snapshot::MemorySnapshot,ctx::RuntimeContext;tool="memory.retrieve")
    memory_scope_id(snapshot.store,ctx)==snapshot.scope_id ||
        throw(ShenScopeError(:permission,"Memory snapshot belongs to another runtime scope"))
    current=memory_snapshot(snapshot.store,ctx;tool,authorized=true)
    current.id==snapshot.id || throw(ShenScopeError(:conflict,"Memory changed while preparing the result"))
    nothing
end

function memory_document_record(document::MemoryDocument)
    Dict("kind"=>"versioned","key"=>document.key,"version"=>document.version,
        "sha256"=>document.record_sha256,"value"=>deepcopy(document.value),"deleted"=>document.deleted,
        "created"=>document.created,"updated"=>document.updated)
end
