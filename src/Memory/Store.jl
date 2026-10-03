struct MemoryStore
    versions::VersionedStore
    scope::Symbol
    owner::String
end

function check_memory_scope(store::MemoryStore,ctx::RuntimeContext)
    expected=memory_store(ctx,store.scope)
    store.owner==expected.owner && store.versions.journal.path==expected.versions.journal.path ||
        throw(ShenScopeError(:permission,"Memory belongs to another runtime scope"))
    nothing
end

function memory_store(ctx::RuntimeContext,scope::Symbol=:workspace)
    scope in (:workspace,:session,:user) || throw(ShenScopeError(:memory,"Unknown memory scope"))
    owner=scope==:workspace ? digest(ctx.root) : scope==:session ? valid_id(ctx.session_id) : "local-user"
    path=joinpath(ctx.state_dir,"memory",String(scope),owner*".jsonl")
    MemoryStore(VersionedStore(path),scope,owner)
end

function memory_visible(record::AbstractDict;at=time())
    record["deleted"] && return false
    expires=get(record["value"],"expires",nothing)
    return expires===nothing || expires>at
end

function memory_put!(store::MemoryStore,key::AbstractString,content::AbstractString,ctx::RuntimeContext;
        expected_version::Integer,title=String(key),tags=String[],source="user",expires=nothing)
    check_memory_scope(store,ctx)
    value=memory_value(store,content;title,tags,source,expires)
    authorize!(ctx,:persistence,"memory.put",String(store.scope)*":"*object_key(key);reason="Persist scoped memory")
    return version_put!(store.versions,key,value;expected_version)
end

function memory_value(store::MemoryStore,content::AbstractString;title,tags=String[],source="user",expires=nothing)
    ncodeunits(content)<=64*1024 && isvalid(content) || throw(ShenScopeError(:memory,"Memory content exceeds limit or is invalid"))
    ncodeunits(title)<=512 && length(tags)<=32 && all(t->t isa String && ncodeunits(t)<=128,tags) ||
        throw(ShenScopeError(:memory,"Invalid memory metadata"))
    source in ("user","agent","tool","import") || throw(ShenScopeError(:memory,"Unknown provenance source"))
    expires===nothing || (expires isa Real && !(expires isa Bool) && isfinite(expires) && expires>time()) ||
        throw(ShenScopeError(:memory,"Expiry must be a future finite Unix timestamp"))
    Dict("title"=>String(title),"content"=>String(content),"tags"=>String.(tags),
        "source"=>source,"scope"=>String(store.scope),"owner"=>store.owner,
        "content_sha256"=>digest(content),"expires"=>expires)
end

function memory_get(store::MemoryStore,key::AbstractString,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    authorize!(ctx,:read,"memory.get",String(store.scope)*":"*object_key(key))
    value=version_get(store.versions,key)
    return value!==nothing && memory_visible(value) ? value : nothing
end

function memory_delete!(store::MemoryStore,key::AbstractString,ctx::RuntimeContext;expected_version::Integer)
    check_memory_scope(store,ctx)
    authorize!(ctx,:persistence,"memory.delete",String(store.scope)*":"*object_key(key);reason="Delete scoped memory")
    previous=version_get(store.versions,key;include_deleted=true)
    previous===nothing && throw(ShenScopeError(:memory,"Memory not found"))
    version_put!(store.versions,key,Dict("scope"=>String(store.scope),"owner"=>store.owner);
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
    check_memory_scope(store,ctx)
    1<=limit<=100 && ncodeunits(query)<=4096 || throw(ShenScopeError(:memory,"Invalid search limits"))
    authorize!(ctx,:read,"memory.search",String(store.scope))
    terms=unique(lexical_tokens(query))
    isempty(terms) && return Dict{String,Any}[]
    records=[r for r in version_list(store.versions) if memory_visible(r;at)]
    isempty(records) && return Dict{String,Any}[]
    frequencies=Dict{String,Int}[];lengths=Int[]
    for record in records
        value=record["value"]
        text=value["title"]*" "*value["title"]*" "*value["content"]*" "*join(value["tags"]," ")
        tokens=lexical_tokens(text);counts=Dict{String,Int}()
        for token in tokens;counts[token]=get(counts,token,0)+1;end
        push!(frequencies,counts);push!(lengths,length(tokens))
    end
    average=max(1.0,sum(lengths)/length(lengths));results=Dict{String,Any}[]
    document_frequency=Dict(term=>count(f->haskey(f,term),frequencies) for term in terms)
    for (i,record) in enumerate(records)
        score=0.0;matched=String[]
        for term in terms
            frequency=get(frequencies[i],term,0);frequency==0 && continue
            idf=log1p((length(records)-document_frequency[term]+0.5)/(document_frequency[term]+0.5))
            score+=idf*frequency*2.2/(frequency+1.2*(0.25+0.75*lengths[i]/average))
            push!(matched,term)
        end
        score>0 && push!(results,Dict("key"=>record["key"],"version"=>record["version"],"score"=>score,
            "matched_terms"=>matched,"value"=>record["value"],"sha256"=>record["sha256"]))
    end
    sort!(results;by=r->(-r["score"],r["key"]))
    return results[1:min(limit,length(results))]
end

function memory_export(store::MemoryStore,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    authorize!(ctx,:read,"memory.export",String(store.scope))
    Dict("schema"=>1,"scope"=>String(store.scope),"exported"=>utcstamp(),
        "entries"=>[r for r in version_list(store.versions) if memory_visible(r)])
end

function memory_import!(store::MemoryStore,document::AbstractDict,ctx::RuntimeContext)
    check_memory_scope(store,ctx)
    get(document,"schema",nothing)==1 || throw(ShenScopeError(:memory,"Unsupported memory export version"))
    entries=get(document,"entries",nothing)
    entries isa AbstractVector && length(entries)<=512 || throw(ShenScopeError(:memory,"Invalid import entries"))
    changes=NamedTuple[]
    for entry in entries
        key=object_key(entry["key"])
        value=entry["value"]
        digest(value["content"])==value["content_sha256"] || throw(ShenScopeError(:memory,"Imported content checksum mismatch"))
        prepared=memory_value(store,value["content"];title=value["title"],tags=value["tags"],source="import",expires=get(value,"expires",nothing))
        push!(changes,(;key,value=prepared,expected_version=0,deleted=false))
    end
    authorize!(ctx,:persistence,"memory.import",String(store.scope);reason="Atomically import scoped memory")
    [record["key"] for record in version_batch!(store.versions,changes)]
end

struct MemoryTool <: AbstractTool end
tool_name(::MemoryTool)="memory"
tool_description(::MemoryTool)="Retrieve lexical scoped memory or persist explicitly approved facts with provenance and CAS versions."
execution_mode(::MemoryTool)=:exclusive
tool_schema(::MemoryTool)=object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["get","search","put","delete","history"]),
    "scope"=>Dict("type"=>"string","enum"=>["workspace","session","user"]),"key"=>string_schema(;max=256),
    "query"=>string_schema(;max=4096),"content"=>string_schema(;max=65536),"title"=>string_schema(;max=512),
    "expected_version"=>integer_schema(),"limit"=>integer_schema(1,100));required=["action"])
function execute(::MemoryTool,args::AbstractDict,ctx::RuntimeContext)
    store=memory_store(ctx,Symbol(get(args,"scope","workspace")));action=args["action"]
    if action=="search"
        haskey(args,"query") || throw(ShenScopeError(:arguments,"Search query required"))
        return memory_search(store,args["query"],ctx;limit=get(args,"limit",8))
    end
    haskey(args,"key") || throw(ShenScopeError(:arguments,"Memory key required"))
    if action=="get";return memory_get(store,args["key"],ctx)
    elseif action=="history"
        authorize!(ctx,:read,"memory.history",String(store.scope)*":"*args["key"])
        return version_history(store.versions,args["key"];limit=get(args,"limit",8))
    end
    haskey(args,"expected_version") || throw(ShenScopeError(:arguments,"Expected version required"))
    action=="delete" && return memory_delete!(store,args["key"],ctx;expected_version=args["expected_version"])
    haskey(args,"content") || throw(ShenScopeError(:arguments,"Memory content required"))
    return memory_put!(store,args["key"],args["content"],ctx;expected_version=args["expected_version"],
        title=get(args,"title",args["key"]),source="agent")
end
