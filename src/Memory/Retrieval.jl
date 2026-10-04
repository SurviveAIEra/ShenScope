function memory_retrieve(store::MemoryStore,text::AbstractString,ctx::RuntimeContext;
        options=MemoryRetrievalOptions(),manager=nothing,at=time(),legacy=false)
    options isa MemoryRetrievalOptions && legacy isa Bool || throw(ShenScopeError(:arguments,"Invalid memory retrieval options"))
    query=memory_query(text)
    index=manager===nothing ? memory_index(store,ctx) : memory_index(manager,store,ctx)
    snapshot=index.snapshot
    page=memory_page_position(snapshot,query,options;at)
    result=memory_rank(index,query,options,ctx;at=page.at)
    items=Dict{String,Any}[];retained=0;byte_limited=false
    last=min(length(result.ranked),page.offset+options.limit)
    for position in page.offset+1:last
        memory_checkpoint(ctx,:read,"memory.retrieve",memory_target(store))
        row=result.ranked[position]
        item=if legacy
            document=snapshot.documents[row["document_id"]]
            Dict("key"=>document.key,"version"=>document.version,"score"=>row["score"],
                "matched_terms"=>copy(row["matched_terms"]),"value"=>deepcopy(document.value),"sha256"=>document.record_sha256)
        else
            preview=memory_preview(snapshot,row,options;at=page.at)
            preview["index_partial"]=row["document_id"] in index.partial_documents
            preview
        end
        bytes=ncodeunits(bounded_canonical_json(item;maximum=MAX_MEMORY_PREVIEW_BYTES))
        if retained+bytes>MAX_MEMORY_PREVIEW_BYTES-8192
            isempty(items) && throw(ShenScopeError(:capacity,"A memory result exceeds its page capacity"))
            byte_limited=true;break
        end
        push!(items,item);retained+=bytes
    end
    memory_snapshot_current!(snapshot,ctx)
    next_offset=page.offset+length(items)
    next_cursor=next_offset<length(result.ranked) ? memory_cursor(snapshot,page.query_id,next_offset,page.at) : nothing
    Dict("schema"=>1,"scope"=>String(store.scope),"owner"=>store.owner,"namespace"=>store.namespace,
        "snapshot"=>snapshot.id,"as_of"=>page.at,"query"=>query.text,"match"=>String(options.match),
        "sort"=>String(options.sort),"filters"=>memory_filters_view(options.filters),
        "offset"=>page.offset,"limit"=>options.limit,"snippet_chars"=>options.snippet_chars,"count"=>length(items),"total_matches"=>length(result.ranked),
        "next_offset"=>next_cursor===nothing ? nothing : next_offset,"next_cursor"=>next_cursor,
        "items"=>items,"scoring"=>memory_scoring_view(result.population,result.averages),
        "coverage"=>Dict("complete"=>snapshot.omitted_records==0 && isempty(index.partial_documents),
            "total_records"=>snapshot.total_records,"captured_records"=>length(snapshot.documents),
            "omitted_records"=>snapshot.omitted_records,"input_bytes"=>snapshot.input_bytes,
            "partial_index_records"=>length(index.partial_documents),"indexed_tokens"=>index.token_count,
            "indexed_postings"=>index.posting_count,"token_omission_events"=>index.omitted_tokens,
            "page_byte_limited"=>byte_limited,"maximum_snapshot_bytes"=>MAX_MEMORY_SNAPSHOT_BYTES,
            "maximum_index_tokens"=>MAX_MEMORY_INDEX_TOKENS,"maximum_index_postings"=>MAX_MEMORY_INDEX_POSTINGS),
        "writes_performed"=>false,"model_requests"=>0)
end

function memory_inventory(store::MemoryStore,ctx::RuntimeContext;at=time())
    at isa Real && !(at isa Bool) && isfinite(at) && at>=0 || throw(ShenScopeError(:arguments,"Invalid memory inventory time"))
    snapshot=memory_snapshot(store,ctx;tool="memory.inventory")
    live=0;expired=0;deleted=0;tags=Dict{String,Int}();sources=Dict{String,Int}()
    content_bytes=0;newest=nothing
    for document in snapshot.documents
        memory_checkpoint(ctx,:read,"memory.inventory",memory_target(store))
        if document.deleted;deleted+=1;continue;end
        expiry=get(document.value,"expires",nothing)
        if expiry!==nothing && expiry<=at;expired+=1;continue;end
        live+=1;content_bytes+=ncodeunits(document.value["content"])
        newest===nothing || newest>=document.updated || (newest=document.updated)
        newest===nothing && (newest=document.updated)
        source=String(document.value["source"]);sources[source]=get(sources,source,0)+1
        for tag in unique(document.value["tags"]);tags[tag]=get(tags,tag,0)+1;end
    end
    facets=sort!(collect(tags);by=pair->(-last(pair),first(pair)))
    memory_snapshot_current!(snapshot,ctx;tool="memory.inventory")
    Dict("schema"=>1,"scope"=>String(store.scope),"owner"=>store.owner,"namespace"=>store.namespace,
        "snapshot"=>snapshot.id,"as_of"=>Float64(at),"live"=>live,"expired"=>expired,"deleted"=>deleted,
        "total_records"=>snapshot.total_records,"captured_records"=>length(snapshot.documents),
        "omitted_records"=>snapshot.omitted_records,"complete"=>snapshot.omitted_records==0,
        "live_content_bytes"=>content_bytes,"latest_update"=>newest,"sources"=>sources,
        "tags"=>[Dict("tag"=>first(pair),"count"=>last(pair)) for pair in facets[1:min(length(facets),32)]],
        "omitted_tag_facets"=>max(0,length(facets)-32),"entry_limit"=>store.versions.max_entries,
        "journal_byte_limit"=>store.versions.max_log_bytes,"retained_versions_per_key"=>store.versions.history_limit,
        "namespace_limit"=>MAX_MEMORY_NAMESPACES,"expiration_is_visibility_filter"=>true,
        "deletion_is_tombstone"=>true,"secure_erasure"=>false)
end

function memory_history(store::MemoryStore,key::AbstractString,ctx::RuntimeContext;limit=8)
    check_memory_scope(store,ctx);object_key(key)
    limit isa Integer && !(limit isa Bool) && 1<=limit<=100 || throw(ShenScopeError(:arguments,"Invalid memory history limit"))
    authorize!(ctx,:read,"memory.history",memory_target(store,key))
    memory_checkpoint(ctx,:read,"memory.history",memory_target(store,key))
    memory_records(store,ctx;tool="memory.history",authorized=true)
    memory_namespace_registered(store,ctx) && isfile(store.versions.journal.path) || return Dict{String,Any}[]
    records=version_history(store.versions,key;limit)
    for record in records;validate_memory_record(store,record);end
    memory_store_guard(store.versions,ctx)
    memory_checkpoint(ctx,:read,"memory.history",memory_target(store,key))
    records
end
