function analyzer_result_number(value,label::String)
    value isa Real && !(value isa Bool) && isfinite(value) && 0 <= value <= 1 ||
        throw(ShenScopeError(:analysis,"Analyzer "*label*" must be finite and between zero and one"))
    Float64(value)
end

function analyzer_evidence_component(snapshot::AnalyzerGraphSnapshot,symbol_id::String,identifiers::AbstractVector)
    length(identifiers) <= 64 && all(id -> id isa AbstractString && haskey(snapshot.relations,id),identifiers) &&
        length(unique(identifiers)) == length(identifiers) || throw(ShenScopeError(:analysis,"Analyzer evidence contains missing, duplicate or excessive relations"))
    isempty(identifiers) && return (edges=Dict{String,Any}[],confidence_cap=0.0,seed_connected=false)
    adjacency = Dict{String,Set{String}}()
    edges = Dict{String,Any}[]
    for identifier in identifiers
        edge = snapshot.relations[identifier]
        push!(get!(Set{String},adjacency,edge["src"]),edge["dst"])
        push!(get!(Set{String},adjacency,edge["dst"]),edge["src"])
        push!(edges,deepcopy(edge))
    end
    haskey(adjacency,symbol_id) || throw(ShenScopeError(:analysis,"Analyzer evidence does not reference its candidate"))
    visited = Set{String}();queue = [symbol_id]
    while !isempty(queue)
        current = pop!(queue)
        current in visited && continue;push!(visited,current)
        append!(queue,get(adjacency,current,Set{String}()))
    end
    all(edge -> edge["src"] in visited && edge["dst"] in visited,edges) ||
        throw(ShenScopeError(:analysis,"Analyzer evidence contains an unrelated relation component"))
    seed_connected = !isempty(intersect(visited,snapshot.seed_ids))
    confidence_cap = minimum(Float64(edge["confidence"]) for edge in edges)
    (edges=edges,confidence_cap=confidence_cap,seed_connected=seed_connected)
end

function analyzer_graph_result(snapshot::AnalyzerGraphSnapshot,raw::AbstractDict;max_candidates=1000)
    allowed = Set(["candidates","notes","truncated"])
    Set(keys(raw)) <= allowed && haskey(raw,"candidates") && raw["candidates"] isa AbstractVector &&
        length(raw["candidates"]) <= max_candidates || throw(ShenScopeError(:analysis,"Analyzer graph result shape or candidate capacity is invalid"))
    notes = get(raw,"notes",Any[]);truncated = get(raw,"truncated",false)
    notes isa AbstractVector && length(notes) <= 16 && all(note -> note isa AbstractString && isvalid(note) && ncodeunits(note) <= 2048,notes) &&
        truncated isa Bool || throw(ShenScopeError(:analysis,"Analyzer graph notes or truncation flag is invalid"))
    candidates = Dict{String,Any}[];seen = Set{String}()
    fields = Set(["symbol_id","score","confidence","reason","evidence"])
    for candidate in raw["candidates"]
        candidate isa AbstractDict && Set(keys(candidate)) == fields &&
            candidate["symbol_id"] isa AbstractString && haskey(snapshot.symbols,candidate["symbol_id"]) &&
            candidate["reason"] isa AbstractString && isvalid(candidate["reason"]) && 1 <= ncodeunits(candidate["reason"]) <= 2048 &&
            candidate["evidence"] isa AbstractVector || throw(ShenScopeError(:analysis,"Analyzer candidate has unknown symbols or invalid fields"))
        id = String(candidate["symbol_id"])
        id in seen && throw(ShenScopeError(:analysis,"Analyzer returned duplicate symbol candidates"));push!(seen,id)
        score = analyzer_result_number(candidate["score"],"score")
        confidence = analyzer_result_number(candidate["confidence"],"confidence")
        evidence = analyzer_evidence_component(snapshot,id,candidate["evidence"])
        confidence <= evidence.confidence_cap + eps(Float64) ||
            throw(ShenScopeError(:analysis,"Analyzer confidence exceeds its recorded relation evidence"))
        push!(candidates,Dict("symbol"=>deepcopy(snapshot.symbols[id]),"score"=>score,"confidence"=>confidence,
            "reason"=>String(candidate["reason"]),"evidence"=>String.(candidate["evidence"]),
            "relation_evidence"=>evidence.edges,"seed_connected"=>evidence.seed_connected,
            "provenance"=>"generated_analyzer","claim_status"=>"hypothesis_with_recorded_evidence"))
    end
    sort!(candidates;by=candidate -> (-candidate["score"],candidate["symbol"]["id"]))
    Dict("revision"=>snapshot.revision,"fingerprint"=>snapshot.fingerprint,"backend"=>snapshot.data["backend"],
        "scope"=>snapshot.data["scope"],"coverage"=>deepcopy(snapshot.data["coverage"]),
        "candidates"=>candidates,"notes"=>String.(notes),"truncated"=>truncated || snapshot.data["truncated"],
        "limitations"=>["Only facts in the supplied indexed snapshot are available; this does not verify current disk or runtime behavior.",
            "Evidence identity and connectivity are checked. Generated reasons and scores remain hypotheses.",
            "Confidence is bounded by recorded relation evidence; it is not a probability of correctness."])
end
