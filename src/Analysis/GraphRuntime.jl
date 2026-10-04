struct IsolatedJuliaAnalyzer <: AbstractAnalyzer
    manager::AnalyzerManager
    name::String
    version::Union{Nothing,String}
end
IsolatedJuliaAnalyzer(manager::AnalyzerManager,name::AbstractString;version=nothing) =
    IsolatedJuliaAnalyzer(manager,String(name),version === nothing ? nothing : String(version))
analyzer_name(analyzer::IsolatedJuliaAnalyzer) = analyzer.name
requirements(::IsolatedJuliaAnalyzer) = [:definitions,:relations]

function analyze(analyzer::IsolatedJuliaAnalyzer,state::ProjectState,request::AbstractDict,ctx::RuntimeContext)
    maximum = get(request,"max_candidates",1000)
    maximum isa Integer && !(maximum isa Bool) && 1 <= maximum <= 1000 ||
        throw(ShenScopeError(:arguments,"Invalid analyzer candidate capacity"))
    snapshot = analyzer_graph_snapshot(state,request,ctx)
    limits = analyzer_graph_limits(request)
    result = evaluate_analyzer!(analyzer.manager,analyzer.name,snapshot.data,request,ctx;version=analyzer.version)
    graph_result = analyzer_graph_result(snapshot,result["result"];
        max_candidates=min(maximum,limits.symbols))
    analyzer_graph_current!(snapshot,state,ctx)
    enriched = merge(graph_result,Dict("analyzer"=>analyzer.name,"version"=>result["version"],
        "validation"=>result["validation"],"lifetime"=>"session"))
    ncodeunits(canonical(enriched)) <= result["validation"]["limits"]["output_bytes"] ||
        throw(ShenScopeError(:capacity,"Grounded analyzer result exceeds output capacity; request fewer candidates"))
    emit!(ctx,:analyzer_graph_completed,Dict("name"=>analyzer.name,"version"=>result["version"],
        "revision"=>snapshot.revision,"candidates"=>length(graph_result["candidates"])))
    enriched
end
