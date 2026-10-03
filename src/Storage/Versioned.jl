struct VersionedStore
    journal::Journal
    max_entries::Int
    max_log_bytes::Int
    history_limit::Int
end
function VersionedStore(path::AbstractString;max_entries=512,max_log_bytes=32*1024*1024,history_limit=8)
    max_entries>0 && max_log_bytes>=1024 && 1<=history_limit<=100 || throw(ArgumentError("Invalid versioned store limits"))
    VersionedStore(Journal(path),max_entries,max_log_bytes,history_limit)
end

function store_versions(store::VersionedStore)
    records=journal_records(store.journal)
    latest=Dict{String,Dict{String,Any}}()
    for record in records
        get(record,"kind",nothing)=="versioned" || throw(ShenScopeError(:storage,"Unknown versioned store event"))
        key=record["key"]
        record["version"]>get(get(latest,key,Dict()),"version",0) ||
            throw(ShenScopeError(:storage,"Non-monotonic object version"))
        latest[key]=record
    end
    return records,latest
end

function object_key(key::AbstractString)
    !isempty(strip(key)) && isvalid(key) && ncodeunits(key)<=256 && !occursin('\0',key) ||
        throw(ShenScopeError(:input,"Invalid object key"))
    return String(key)
end

function version_get(store::VersionedStore,key::AbstractString;include_deleted=false)
    key=object_key(key)
    return store_lock(store.journal.path*".transaction") do
        _,latest=store_versions(store)
        value=get(latest,key,nothing)
        value===nothing && return nothing
        !include_deleted && value["deleted"] && return nothing
        return deepcopy(value)
    end
end

function version_list(store::VersionedStore;include_deleted=false)
    return store_lock(store.journal.path*".transaction") do
        _,latest=store_versions(store)
        [deepcopy(v) for (_,v) in sort!(collect(latest);by=first) if include_deleted || !v["deleted"]]
    end
end

function journal_frames(records::AbstractVector)
    io=IOBuffer()
    for (sequence,record) in enumerate(records)
        write(io,canonical(Dict("schema"=>1,"sequence"=>sequence,"record"=>record,
            "sha256"=>digest(canonical(record)))),"\n")
    end
    return String(take!(io))
end

function compact_versions!(store::VersionedStore,records::Vector)
    counts=Dict{String,Int}();retained=Dict{String,Any}[]
    for record in reverse(records)
        key=record["key"];count=get(counts,key,0)
        count>=store.history_limit && continue
        push!(retained,record);counts[key]=count+1
    end
    reverse!(retained)
    text=journal_frames(retained)
    ncodeunits(text)<=store.max_log_bytes || throw(ShenScopeError(:storage,"Version history exceeds store capacity"))
    atomic_write(store.journal.path,text)
    return retained
end

function version_put!(store::VersionedStore,key::AbstractString,value;expected_version::Integer,deleted=false)
    only(version_batch!(store,[(;key,value,expected_version,deleted)]))
end

function version_batch!(store::VersionedStore,changes::AbstractVector)
    length(changes)<=store.max_entries || throw(ShenScopeError(:input,"Batch exceeds object limit"))
    prepared=NamedTuple[];seen=Set{String}()
    for change in changes
        key=object_key(change.key)
        key in seen && throw(ShenScopeError(:input,"Duplicate batch key"));push!(seen,key)
        change.expected_version isa Integer && !(change.expected_version isa Bool) && change.expected_version>=0 ||
            throw(ShenScopeError(:input,"Invalid expected version"))
        change.deleted isa Bool || throw(ShenScopeError(:input,"Invalid deletion flag"))
        serialized=canonical(change.value)
        ncodeunits(serialized)<=128*1024 || throw(ShenScopeError(:input,"Stored value exceeds limit"))
        push!(prepared,(;key,serialized,expected_version=change.expected_version,deleted=change.deleted))
    end
    return store_lock(store.journal.path*".transaction") do
        records,latest=store_versions(store)
        added=Dict{String,Any}[]
        for change in prepared
            prior=get(latest,change.key,nothing)
            observed=prior===nothing ? 0 : prior["version"]
            observed==change.expected_version || throw(ShenScopeError(:conflict,"Object version changed"))
            record=Dict{String,Any}("kind"=>"versioned","key"=>change.key,"version"=>observed+1,
                "sha256"=>digest(change.serialized),"value"=>parsejson(change.serialized),"deleted"=>change.deleted,
                "created"=>prior===nothing ? utcstamp() : prior["created"],"updated"=>utcstamp())
            push!(added,record);latest[change.key]=record
        end
        length(latest)<=store.max_entries || throw(ShenScopeError(:storage,"Object count limit reached"))
        # Compact an in-memory candidate before touching the journal. Failed
        # capacity checks leave the existing store intact.
        isempty(added) || compact_versions!(store,vcat(records,added))
        return deepcopy(added)
    end
end

function version_history(store::VersionedStore,key::AbstractString;limit=8)
    1<=limit<=100 || throw(ShenScopeError(:input,"Invalid history limit"))
    key=object_key(key)
    return store_lock(store.journal.path*".transaction") do
        records,_=store_versions(store)
        matching=[deepcopy(r) for r in records if r["key"]==key]
        reverse(matching[max(1,length(matching)-limit+1):end])
    end
end
