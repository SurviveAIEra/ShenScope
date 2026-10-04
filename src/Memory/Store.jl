function memory_visible(record::AbstractDict;at=time())
    record["deleted"] && return false
    expires=get(record["value"],"expires",nothing)
    return expires===nothing || expires>at
end

function memory_put!(store::MemoryStore,key::AbstractString,content::AbstractString,ctx::RuntimeContext;
        expected_version::Integer,title=String(key),tags=String[],source="user",expires=nothing,
        source_reference="")
    check_memory_scope(store,ctx)
    object_key(key)
    memory_version(expected_version;allow_zero=true)
    value=memory_value(store,content;title,tags,source,expires,source_reference)
    value["origin_session_id"]=ctx.session_id
    authorize!(ctx,:persistence,"memory.put",memory_target(store,key);reason="Persist namespaced scoped memory")
    memory_checkpoint(ctx,:persistence,"memory.put",memory_target(store,key))
    memory_records(store,ctx;tool="memory.put",authorized=true,category=:persistence,require_namespace=false)
    register_memory_namespace!(store,ctx)
    memory_store_guard(store.versions,ctx)
    return version_put!(store.versions,key,value;expected_version)
end

function memory_value(store::MemoryStore,content::AbstractString;title,tags=String[],source="user",expires=nothing,
        source_reference="")
    ncodeunits(content)<=64*1024 && isvalid(content) || throw(ShenScopeError(:memory,"Memory content exceeds limit or is invalid"))
    title isa AbstractString && isvalid(title) && ncodeunits(title)<=512 &&
        tags isa AbstractVector && length(tags)<=32 &&
        all(t->t isa AbstractString && isvalid(t) && !isempty(strip(t)) && ncodeunits(t)<=128,tags) ||
        throw(ShenScopeError(:memory,"Invalid memory metadata"))
    source_reference isa AbstractString && isvalid(source_reference) && ncodeunits(source_reference)<=512 ||
        throw(ShenScopeError(:memory,"Invalid source reference"))
    source in ("user","agent","tool","import") || throw(ShenScopeError(:memory,"Unknown provenance source"))
    expires===nothing || (expires isa Real && !(expires isa Bool) && isfinite(expires) && expires>time()) ||
        throw(ShenScopeError(:memory,"Expiry must be a future finite Unix timestamp"))
    Dict("title"=>String(title),"content"=>String(content),"tags"=>String.(tags),
        "source"=>source,"scope"=>String(store.scope),"owner"=>store.owner,"namespace"=>store.namespace,
        "workspace_sha256"=>store.workspace_sha256,
        "source_reference"=>String(source_reference),"provenance_verified"=>false,
        "content_sha256"=>digest(content),"expires"=>expires)
end

function memory_get(store::MemoryStore,key::AbstractString,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    authorize!(ctx,:read,"memory.get",memory_target(store,key))
    memory_namespace_registered(store,ctx) && isfile(store.versions.journal.path) || return nothing
    records=memory_records(store,ctx;tool="memory.get",authorized=true)
    position=findfirst(record->record["key"]==key,records)
    value=position===nothing ? nothing : records[position]
    memory_checkpoint(ctx,:read,"memory.get",memory_target(store,key))
    return value!==nothing && memory_visible(value) ? value : nothing
end

function memory_delete!(store::MemoryStore,key::AbstractString,ctx::RuntimeContext;expected_version::Integer)
    check_memory_scope(store,ctx)
    memory_version(expected_version;allow_zero=true)
    authorize!(ctx,:persistence,"memory.delete",memory_target(store,key);reason="Delete namespaced scoped memory")
    memory_namespace_registered(store,ctx;category=:persistence) && isfile(store.versions.journal.path) ||
        throw(ShenScopeError(:memory,"Memory not found"))
    records=memory_records(store,ctx;tool="memory.delete",authorized=true,category=:persistence)
    position=findfirst(record->record["key"]==key,records)
    previous=position===nothing ? nothing : records[position]
    previous===nothing && throw(ShenScopeError(:memory,"Memory not found"))
    validate_memory_record(store,previous)
    memory_checkpoint(ctx,:persistence,"memory.delete",memory_target(store,key))
    memory_store_guard(store.versions,ctx)
    version_put!(store.versions,key,Dict("scope"=>String(store.scope),"owner"=>store.owner,"namespace"=>store.namespace,
        "workspace_sha256"=>store.workspace_sha256);
        expected_version,deleted=true)
end

is_han(char::Char)=0x3400<=UInt32(char)<=0x9fff || 0x20000<=UInt32(char)<=0x323af
function lexical_tokens(text::AbstractString)
    tokens=String[];latin=IOBuffer();han=Char[]
    flush_latin=()->begin
        position(latin)>0 && push!(tokens,lowercase(String(take!(latin))))
    end
    flush_han=()->begin
        for char in han;push!(tokens,string(char));end
        for i in 1:length(han)-1;push!(tokens,string(han[i],han[i+1]));end
        empty!(han)
    end
    for char in text
        if is_han(char)
            flush_latin();push!(han,char)
        elseif isletter(char) || isnumeric(char) || char=='_'
            flush_han();write(latin,char)
        else
            flush_latin();flush_han()
        end
    end
    flush_latin();flush_han()
    return tokens
end

function memory_search(store::MemoryStore,query::AbstractString,ctx::RuntimeContext;limit=8,at=time())
    isvalid(query) && ncodeunits(query)<=MAX_MEMORY_QUERY_BYTES || throw(ShenScopeError(:arguments,"Invalid memory search query"))
    options=MemoryRetrievalOptions(;limit)
    if isempty(strip(query))
        check_memory_scope(store,ctx);authorize!(ctx,:read,"memory.search",memory_target(store))
        memory_checkpoint(ctx,:read,"memory.search",memory_target(store))
        return Dict{String,Any}[]
    end
    memory_retrieve(store,query,ctx;options,at,legacy=true)["items"]
end

function memory_export(store::MemoryStore,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    records=memory_records(store,ctx;tool="memory.export")
    result=Dict("schema"=>1,"scope"=>String(store.scope),"namespace"=>store.namespace,"exported"=>utcstamp(),
        "entries"=>[record for record in records if memory_visible(record)])
    bounded_canonical_json(result;maximum=MAX_MEMORY_PREVIEW_BYTES)
    memory_checkpoint(ctx,:read,"memory.export",memory_target(store))
    result
end

function memory_import!(store::MemoryStore,document::AbstractDict,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    get(document,"schema",nothing)===1 || throw(ShenScopeError(:memory,"Unsupported memory export version"))
    bounded_canonical_json(document;maximum=MAX_MEMORY_PREVIEW_BYTES)
    entries=get(document,"entries",nothing)
    entries isa AbstractVector && length(entries)<=512 || throw(ShenScopeError(:memory,"Invalid import entries"))
    changes=NamedTuple[];seen=Set{String}()
    for entry in entries
        entry isa AbstractDict && get(entry,"key",nothing) isa AbstractString &&
            get(entry,"value",nothing) isa AbstractDict || throw(ShenScopeError(:memory,"Invalid memory import entry"))
        key=object_key(entry["key"])
        key in seen && throw(ShenScopeError(:memory,"Duplicate memory import key"));push!(seen,key)
        value=entry["value"]
        get(value,"content",nothing) isa AbstractString && get(value,"title",nothing) isa AbstractString &&
            get(value,"tags",nothing) isa AbstractVector || throw(ShenScopeError(:memory,"Invalid imported memory value"))
        digest(value["content"])==get(value,"content_sha256",nothing) || throw(ShenScopeError(:memory,"Imported content checksum mismatch"))
        prepared=memory_value(store,value["content"];title=value["title"],tags=value["tags"],source="import",
            expires=get(value,"expires",nothing),source_reference=get(value,"source_reference",""))
        prepared["origin_session_id"]=ctx.session_id
        push!(changes,(;key,value=prepared,expected_version=0,deleted=false))
    end
    authorize!(ctx,:persistence,"memory.import",memory_target(store);reason="Atomically import namespaced scoped memory")
    memory_checkpoint(ctx,:persistence,"memory.import",memory_target(store))
    memory_records(store,ctx;tool="memory.import",authorized=true,category=:persistence,require_namespace=false)
    isempty(changes) || register_memory_namespace!(store,ctx)
    memory_store_guard(store.versions,ctx)
    [record["key"] for record in version_batch!(store.versions,changes)]
end
