function memory_string_filter(value,name;maximum=32,bytes=128,allowed=nothing)
    value isa AbstractVector && length(value)<=maximum ||
        throw(ShenScopeError(:arguments,"Invalid memory "*name*" filter"))
    values=String[]
    for item in value
        item isa AbstractString && isvalid(item) && !isempty(strip(item)) && ncodeunits(item)<=bytes &&
            (allowed===nothing || item in allowed) ||
            throw(ShenScopeError(:arguments,"Invalid memory "*name*" filter entry"))
        push!(values,String(item))
    end
    Tuple(sort!(unique(values)))
end

function MemoryFilters(;tags_all=String[],tags_any=String[],sources=String[],
        include_expired=false,include_deleted=false,updated_after=nothing,updated_before=nothing)
    include_expired isa Bool && include_deleted isa Bool ||
        throw(ShenScopeError(:arguments,"Memory visibility flags must be boolean"))
    after=updated_after===nothing ? nothing : memory_timestamp(updated_after;argument=true)
    before=updated_before===nothing ? nothing : memory_timestamp(updated_before;argument=true)
    after===nothing || before===nothing || after<=before ||
        throw(ShenScopeError(:arguments,"Memory update interval is reversed"))
    MemoryFilters(memory_string_filter(tags_all,"all-tags"),memory_string_filter(tags_any,"any-tags"),
        memory_string_filter(sources,"source";maximum=4,allowed=("user","agent","tool","import")),
        include_expired,include_deleted,after,before)
end

function MemoryRetrievalOptions(;filters=MemoryFilters(),match=:any,sort=:relevance,offset=0,limit=20,
        snippet_chars=240,expected_snapshot=nothing,cursor=nothing)
    filters isa MemoryFilters || throw(ShenScopeError(:arguments,"Invalid memory filters"))
    match=match isa AbstractString ? Symbol(match) : match
    sort=sort isa AbstractString ? Symbol(sort) : sort
    match in (:any,:all) && sort in (:relevance,:key,:updated) ||
        throw(ShenScopeError(:arguments,"Unknown memory match or sort mode"))
    all(value->value isa Integer && !(value isa Bool),(offset,limit,snippet_chars)) &&
        0<=offset<=100000 && 1<=limit<=100 && 40<=snippet_chars<=2000 ||
        throw(ShenScopeError(:arguments,"Invalid memory page or snippet limits"))
    expected_snapshot===nothing || expected_snapshot isa AbstractString &&
        occursin(r"^[0-9a-f]{64}$",expected_snapshot) || throw(ShenScopeError(:arguments,"Invalid memory snapshot identity"))
    cursor===nothing || cursor isa AbstractString && ncodeunits(cursor)<=2048 &&
        occursin(r"^[0-9a-f]+$",cursor) && iseven(ncodeunits(cursor)) ||
        throw(ShenScopeError(:arguments,"Invalid memory cursor"))
    cursor===nothing || offset==0 || throw(ShenScopeError(:arguments,"Choose an offset or a cursor"))
    MemoryRetrievalOptions(filters,match,sort,Int(offset),Int(limit),Int(snippet_chars),
        expected_snapshot===nothing ? nothing : String(expected_snapshot),cursor===nothing ? nothing : String(cursor))
end

function memory_filters_view(filters::MemoryFilters)
    Dict("tags_all"=>collect(filters.tags_all),"tags_any"=>collect(filters.tags_any),"sources"=>collect(filters.sources),
        "include_expired"=>filters.include_expired,"include_deleted"=>filters.include_deleted,
        "updated_after"=>filters.updated_after,"updated_before"=>filters.updated_before)
end

function memory_document_matches(document::MemoryDocument,filters::MemoryFilters,at::Real)
    document.deleted && !filters.include_deleted && return false
    expires=get(document.value,"expires",nothing)
    !document.deleted && expires!==nothing && expires<=at && !filters.include_expired && return false
    tags=get(document.value,"tags",String[])
    all(tag->tag in tags,filters.tags_all) || return false
    isempty(filters.tags_any) || any(tag->tag in tags,filters.tags_any) || return false
    isempty(filters.sources) || get(document.value,"source",nothing) in filters.sources || return false
    filters.updated_after===nothing || document.updated>=filters.updated_after || return false
    filters.updated_before===nothing || document.updated<=filters.updated_before || return false
    true
end

function memory_options_from_arguments(args::AbstractDict)
    filters=MemoryFilters(;tags_all=get(args,"tags_all",String[]),tags_any=get(args,"tags_any",String[]),
        sources=get(args,"sources",String[]),include_expired=get(args,"include_expired",false),
        include_deleted=get(args,"include_deleted",false),updated_after=get(args,"updated_after",nothing),
        updated_before=get(args,"updated_before",nothing))
    MemoryRetrievalOptions(;filters,match=get(args,"match","any"),sort=get(args,"sort","relevance"),
        offset=get(args,"offset",0),limit=get(args,"limit",20),snippet_chars=get(args,"snippet_chars",240),
        expected_snapshot=get(args,"expected_snapshot",nothing),cursor=get(args,"cursor",nothing))
end
