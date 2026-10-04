const MEMORY_FIELD_WEIGHTS = (2.0,1.0,1.5)
const MEMORY_BM25_K1 = 1.2
const MEMORY_BM25_B = 0.75

function memory_phrase_matches(document::MemoryDocument,phrase::String)
    document.deleted && return false
    any(text->occursin(phrase,lowercase(text)),
        (String(document.value["title"]),String(document.value["content"]),join(document.value["tags"]," ")))
end

function memory_excluded_in_partial(document::MemoryDocument,excluded::Tuple)
    isempty(excluded) && return false
    document.deleted && return false
    terms=Set(excluded)
    for field in (document.value["title"],document.value["content"],join(document.value["tags"]," "))
        any(token->token in terms,lexical_tokens(field)) && return true
    end
    false
end

function memory_rank(index::MemoryLexicalIndex,query::MemoryQuery,options::MemoryRetrievalOptions,
        ctx::RuntimeContext;at=time())
    at isa Real && !(at isa Bool) && isfinite(at) && at>=0 || throw(ShenScopeError(:arguments,"Invalid memory query time"))
    snapshot=index.snapshot;target=memory_target(snapshot.store)
    eligible=Set{Int}()
    for (id,document) in enumerate(snapshot.documents)
        memory_checkpoint(ctx,:read,"memory.retrieve",target)
        memory_document_matches(document,options.filters,at) && push!(eligible,id)
    end
    population=length(eligible)
    averages=ntuple(field->max(1.0,sum(index.lengths[id][field] for id in eligible;init=0)/max(1,population)),3)
    positive=sort!(unique(vcat(collect(query.optional),collect(query.required))))
    scores=Dict{Int,Float64}();matched=Dict{Int,Set{String}}()
    contributions=Dict{Int,Vector{Dict{String,Any}}}()
    witnesses=Dict{Int,Vector{Dict{String,Any}}}()
    for term in positive
        postings=get(index.postings,term,MemoryPosting[])
        frequency=count(posting->posting.document in eligible,postings)
        frequency==0 && continue
        idf=log1p((population-frequency+0.5)/(frequency+0.5))
        for posting in postings
            id=posting.document;id in eligible || continue
            memory_checkpoint(ctx,:read,"memory.retrieve",target;cooperate=false)
            counts=(posting.title_count,posting.content_count,posting.tags_count)
            normalized=ntuple(field->MEMORY_FIELD_WEIGHTS[field]*counts[field]/
                (1-MEMORY_BM25_B+MEMORY_BM25_B*index.lengths[id][field]/averages[field]),3)
            total=sum(normalized)
            score=idf*(MEMORY_BM25_K1+1)*total/(MEMORY_BM25_K1+total)
            scores[id]=get(scores,id,0.0)+score
            push!(get!(()->Set{String}(),matched,id),term)
            push!(get!(()->Dict{String,Any}[],contributions,id),Dict("term"=>term,"score"=>score,
                "idf"=>idf,"document_frequency"=>frequency,"normalized_frequency"=>total,
                "field_frequencies"=>Dict("title"=>counts[1],"content"=>counts[2],"tags"=>counts[3])))
            spans=(posting.title_span,posting.content_span,posting.tags_span)
            for (field,name) in enumerate(("title","content","tags"))
                spans[field]===nothing && continue
                start,stop=spans[field]
                push!(get!(()->Dict{String,Any}[],witnesses,id),Dict("term"=>term,"field"=>name,
                    "start_byte"=>start-1,"end_byte"=>stop-1,"encoding"=>"utf8_byte","end_exclusive"=>true))
            end
        end
        memory_checkpoint(ctx,:read,"memory.retrieve",target)
    end
    excluded=Set{Int}()
    for term in query.excluded
        for posting in get(index.postings,term,MemoryPosting[]);push!(excluded,posting.document);end
    end
    ranked=Dict{String,Any}[]
    for id in sort!(collect(eligible))
        memory_checkpoint(ctx,:read,"memory.retrieve",target)
        id in excluded && continue
        document=snapshot.documents[id]
        id in index.partial_documents && memory_excluded_in_partial(document,query.excluded) && continue
        terms=get(matched,id,Set{String}())
        all(term->term in terms,query.required) || continue
        if !isempty(positive)
            isempty(terms) && continue
            options.match==:all && !all(term->term in terms,positive) && continue
        end
        all(phrase->memory_phrase_matches(document,phrase),query.phrases) || continue
        any(phrase->memory_phrase_matches(document,phrase),query.excluded_phrases) && continue
        push!(ranked,Dict("document_id"=>id,"score"=>get(scores,id,0.0),"matched_terms"=>sort!(collect(terms)),
            "contributions"=>get(contributions,id,Dict{String,Any}[]),"witnesses"=>get(witnesses,id,Dict{String,Any}[])))
    end
    if options.sort==:relevance
        sort!(ranked;by=row->(-row["score"],snapshot.documents[row["document_id"]].key))
    elseif options.sort==:key
        sort!(ranked;by=row->snapshot.documents[row["document_id"]].key)
    else
        # Stable two-pass sorting gives descending timestamps and ascending
        # keys for equal timestamps without reversing the key tie-breaker.
        sort!(ranked;by=row->snapshot.documents[row["document_id"]].key)
        sort!(ranked;by=row->snapshot.documents[row["document_id"]].updated,rev=true,alg=Base.Sort.MergeSort)
    end
    (;ranked,population,averages,at=Float64(at))
end

function memory_scoring_view(population,averages)
    Dict("algorithm"=>"bm25f-v1","k1"=>MEMORY_BM25_K1,"b"=>MEMORY_BM25_B,
        "field_weights"=>Dict("title"=>2.0,"content"=>1.0,"tags"=>1.5),
        "population"=>population,"average_field_lengths"=>Dict("title"=>averages[1],
            "content"=>averages[2],"tags"=>averages[3]),"calibrated_confidence"=>false,
        "meaning"=>"Lexical relevance among visible filtered records; provenance does not establish factual truth")
end
