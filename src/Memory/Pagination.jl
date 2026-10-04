function memory_query_identity(query::MemoryQuery,options::MemoryRetrievalOptions)
    digest(canonical(Dict("schema"=>1,"text"=>query.text,"filters"=>memory_filters_view(options.filters),
        "match"=>String(options.match),"sort"=>String(options.sort),"snippet_chars"=>options.snippet_chars)))
end

function memory_cursor(snapshot::MemorySnapshot,query_id::String,offset::Int,at::Float64)
    bytes2hex(codeunits(canonical(Dict("schema"=>1,"snapshot"=>snapshot.id,"scope"=>snapshot.scope_id,
        "query"=>query_id,"offset"=>offset,"at"=>at))))
end

function memory_page_position(snapshot::MemorySnapshot,query::MemoryQuery,options::MemoryRetrievalOptions;at=time())
    at isa Real && !(at isa Bool) && isfinite(at) && at>=0 || throw(ShenScopeError(:arguments,"Invalid memory query time"))
    query_id=memory_query_identity(query,options)
    options.expected_snapshot===nothing || options.expected_snapshot==snapshot.id ||
        throw(ShenScopeError(:conflict,"Memory snapshot changed; start a new page sequence"))
    options.cursor===nothing && return (;offset=options.offset,at=Float64(at),query_id)
    value=try
        bounded_json_object(String(hex2bytes(options.cursor));maximum=1024,max_depth=4,max_nodes=32)
    catch
        throw(ShenScopeError(:arguments,"Memory cursor is malformed"))
    end
    Set(keys(value))==Set(["schema","snapshot","scope","query","offset","at"]) &&
        get(value,"schema",nothing)===1 || throw(ShenScopeError(:arguments,"Memory cursor schema is invalid"))
    value["scope"]==snapshot.scope_id || throw(ShenScopeError(:permission,"Memory cursor belongs to another scope"))
    value["snapshot"]==snapshot.id || throw(ShenScopeError(:conflict,"Memory cursor is stale; restart pagination"))
    value["query"]==query_id || throw(ShenScopeError(:arguments,"Memory cursor does not match this query"))
    offset=value["offset"];issued=value["at"]
    offset isa Integer && !(offset isa Bool) && 0<=offset<=100000 &&
        issued isa Real && !(issued isa Bool) && isfinite(issued) &&
        time()-300<=issued<=time()+1 || throw(ShenScopeError(:arguments,"Memory cursor is expired or invalid"))
    (;offset=Int(offset),at=Float64(issued),query_id)
end

function memory_snippet(document::MemoryDocument,witnesses::AbstractVector;characters=240)
    text=document.deleted ? "" : String(document.value["content"])
    isempty(text) && return Dict("text"=>"","start_byte"=>0,"end_byte"=>0,
        "leading_omitted"=>false,"trailing_omitted"=>false,"highlights"=>Dict{String,Any}[])
    content=[witness for witness in witnesses if witness["field"]=="content"]
    anchor=isempty(content) ? firstindex(text) : minimum(witness["start_byte"] for witness in content)+1
    indices=collect(eachindex(text));position=searchsortedfirst(indices,anchor)
    first_char=max(1,position-div(characters,3));last_char=min(length(indices),first_char+characters-1)
    first_char=max(1,last_char-characters+1)
    start=indices[first_char];stop=last_char==length(indices) ? ncodeunits(text)+1 : indices[last_char+1]
    highlights=Dict{String,Any}[]
    for witness in content
        begin_byte=witness["start_byte"]+1;end_byte=witness["end_byte"]+1
        start<=begin_byte<end_byte<=stop || continue
        push!(highlights,Dict("term"=>witness["term"],"start_byte"=>begin_byte-start,
            "end_byte"=>end_byte-start,"encoding"=>"utf8_byte","end_exclusive"=>true))
    end
    Dict("text"=>String(SubString(text,start,prevind(text,stop))),"start_byte"=>start-1,"end_byte"=>stop-1,
        "leading_omitted"=>start>1,"trailing_omitted"=>stop<ncodeunits(text)+1,"highlights"=>highlights)
end

function memory_preview(snapshot::MemorySnapshot,row::AbstractDict,options::MemoryRetrievalOptions;at=time())
    document=snapshot.documents[row["document_id"]];value=document.value
    contributions=sort!(copy(row["contributions"]);by=item->(-item["score"],item["term"]))
    witnesses=sort!(copy(row["witnesses"]);by=item->(item["field"],item["start_byte"],item["term"]))
    retained_contributions=contributions[1:min(length(contributions),16)]
    retained_witnesses=witnesses[1:min(length(witnesses),64)]
    expires=get(value,"expires",nothing)
    Dict("key"=>document.key,"version"=>document.version,"namespace"=>snapshot.store.namespace,
        "title"=>get(value,"title",document.key),"tags"=>deepcopy(get(value,"tags",String[])),
        "source"=>get(value,"source",nothing),"source_reference"=>get(value,"source_reference",""),
        "origin_session_id"=>get(value,"origin_session_id",nothing),"provenance_verified"=>false,
        "sha256"=>document.record_sha256,"content_sha256"=>document.content_sha256,
        "created"=>document.created,"updated"=>document.updated,"deleted"=>document.deleted,
        "expires"=>expires,"expired"=>!document.deleted && expires!==nothing && expires<=at,
        "score"=>row["score"],"matched_terms"=>copy(row["matched_terms"]),
        "contributions"=>retained_contributions,"omitted_contributions"=>length(contributions)-length(retained_contributions),
        "witnesses"=>retained_witnesses,"omitted_witnesses"=>length(witnesses)-length(retained_witnesses),
        "snippet"=>memory_snippet(document,witnesses;characters=options.snippet_chars),
        "citation"=>Dict("scope"=>String(snapshot.store.scope),"namespace"=>snapshot.store.namespace,
            "key"=>document.key,"version"=>document.version,"record_sha256"=>document.record_sha256,
            "content_sha256"=>document.content_sha256,"snapshot"=>snapshot.id))
end
