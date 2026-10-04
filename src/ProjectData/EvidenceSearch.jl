function evidence_search_score(value::EvidenceSymbol,query::String,terms::Vector{String})
    symbol=value.symbol
    isempty(query) && return symbol.kind==:file ? 0.5 : 1.0
    name=lowercase(symbol.name);qualified=lowercase(symbol.qualified_name)
    tokens=Set(lexical_tokens(symbol.name*" "*symbol.qualified_name*" "*symbol.location.file))
    score=isempty(terms) ? 0.0 : count(term->term in tokens,terms)/length(terms)
    name==query && (score+=3)
    startswith(name,query) && (score+=1)
    occursin(query,qualified) && (score+=0.5)
    symbol.kind==:file ? score*0.5 : score
end

function evidence_search(snapshot::ProjectEvidenceSnapshot,arguments,ctx::RuntimeContext)
    raw=get(arguments,"query","")
    raw isa AbstractString && isvalid(raw) && ncodeunits(raw)<=4096 ||
        throw(ShenScopeError(:arguments,"Invalid combined evidence search"))
    query=lowercase(String(raw));terms=unique(lexical_tokens(query))
    ranked=Tuple{Float64,String}[]
    for (index,key) in enumerate(sort!(collect(keys(snapshot.symbols))))
        index%128==0 && evidence_checkpoint(ctx)
        score=evidence_search_score(snapshot.symbols[key],query,terms)
        score>0 && push!(ranked,(score,key))
    end
    sort!(ranked;by=entry->(-entry[1],entry[2]))
    items=(merge(evidence_symbol_dict(snapshot.symbols[key]),Dict("score"=>score,
        "anchor_id"=>get(snapshot.member_anchors,key,nothing),"score_kind"=>"lexical_relevance")) for (score,key) in ranked)
    result=evidence_page(snapshot,items,arguments,ctx)
    result["limitations"]=["Lexical scores are relevance hints; they do not determine which backend observation is correct.",
        "Provider identities are retained; overlapping declarations are not silently deduplicated."]
    result
end
