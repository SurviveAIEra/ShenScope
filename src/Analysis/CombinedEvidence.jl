function analyze(::ImpactAnalyzer,snapshot::ProjectEvidenceSnapshot,request::AbstractDict,ctx::RuntimeContext)
    snapshot.root==ctx.root || throw(ShenScopeError(:permission,"Evidence analysis belongs to another workspace"))
    seeds=evidence_seed_keys(snapshot,request,ctx)
    traversal=evidence_traverse(snapshot,seeds,ctx)
    seedset=Set(seeds);candidates=Dict{String,Any}[]
    for hit in traversal["hits"]
        hit["key"] in seedset && continue
        push!(candidates,merge(hit,Dict("score"=>hit["confidence"]/(1+hit["depth"]),
            "reason"=>"Reachable through provider relations and explicit source anchors",
            "runtime_execution_confirmed"=>false)))
    end
    sort!(candidates;by=value->(-value["score"],value["depth"],value["key"]))
    result=evidence_page(snapshot,candidates,request,ctx)
    result["analyzer"]="evidence_impact";result["traversal"]=Dict(key=>value for (key,value) in traversal if key!="hits")
    result["limitations"]=["Reachability is indexed evidence, not confirmation that a call executes at runtime.",
        "Source bridges connect identical declaration anchors, not compiler-confirmed runtime bindings.",
        "The first bounded breadth-first witness is retained; heuristic confidence is not an exhaustive best-path computation.",
        "File filters bound the captured graph and can exclude outside callers."]
    result
end

function analyze(::TestSelectionAnalyzer,snapshot::ProjectEvidenceSnapshot,request::AbstractDict,ctx::RuntimeContext)
    seeds=evidence_seed_keys(snapshot,request,ctx)
    traversal=evidence_traverse(snapshot,seeds,ctx)
    candidates=Dict{String,Any}[]
    for hit in traversal["hits"]
        evidence_checkpoint(ctx)
        is_test_symbol(hit["observation"]["symbol"]) || continue
        push!(candidates,merge(hit,Dict("score"=>hit["confidence"]/(1+hit["depth"]),
            "reason"=>hit["depth"]==0 ? "Changed test-named declaration" : "Test-named declaration reachable through combined indexed evidence",
            "runtime_coverage_confirmed"=>false)))
    end
    sort!(candidates;by=value->(-value["score"],value["key"]))
    result=evidence_page(snapshot,candidates,request,ctx)
    result["analyzer"]="evidence_tests"
    result["traversal"]=Dict(key=>value for (key,value) in traversal if key!="hits")
    result["limitations"]=["Test naming and static reachability do not prove runtime test coverage.",
        "Overlapping backend observations retain their independent identities.",
        "Bridge steps consume traversal depth and remain unconfirmed runtime equivalence."]
    result
end
