const INCOMING_ANALYZER_SOURCE = raw"""
function analyze(data, request)
    incoming = Dict{String,Vector{Any}}()
    for edge in data["relations"]
        push!(get!(Vector{Any}, incoming, edge["dst"]), edge)
    end
    candidates = Dict{String,Any}[]
    denominator = max(1, length(data["relations"]))
    for symbol in data["symbols"]
        edges = get(incoming, symbol["id"], Any[])
        isempty(edges) && continue
        push!(candidates, Dict("symbol_id" => symbol["id"],
            "score" => length(edges) / denominator,
            "confidence" => minimum(edge["confidence"] for edge in edges),
            "reason" => string(length(edges), " incoming recorded relations"),
            "evidence" => sort!([edge["id"] for edge in edges])))
    end
    sort!(candidates; by=candidate -> (-candidate["score"], candidate["symbol_id"]))
    Dict("candidates" => candidates, "notes" => ["Incoming relation counts over supplied facts"],
        "truncated" => get(data, "truncated", false))
end
selftest() = isempty(analyze(Dict("symbols" => [], "relations" => []), Dict())["candidates"])
"""

function incoming_analyzer_tests()
    a = repeat("a",32);b = repeat("b",32);edge = repeat("c",64)
    empty_data = Dict("symbols"=>Any[],"relations"=>Any[],"seed_ids"=>Any[],"truncated"=>false)
    notes = ["Incoming relation counts over supplied facts"]
    positive = Dict("symbols"=>[Dict("id"=>a),Dict("id"=>b)],
        "relations"=>[Dict("id"=>edge,"src"=>a,"dst"=>b,"confidence"=>0.5)],"truncated"=>false)
    [AnalyzerTestCase("empty graph",empty_data,Dict(),Dict("candidates"=>Any[],"notes"=>notes,"truncated"=>false)),
        AnalyzerTestCase("one incoming dependency",positive,Dict(),
            Dict("candidates"=>[Dict("symbol_id"=>b,"score"=>1.0,"confidence"=>0.5,
                "reason"=>"1 incoming recorded relations","evidence"=>[edge])],"notes"=>notes,"truncated"=>false))]
end
