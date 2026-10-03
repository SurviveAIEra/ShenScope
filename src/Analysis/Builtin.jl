struct ImpactAnalyzer <: AbstractAnalyzer end
struct TestSelectionAnalyzer <: AbstractAnalyzer end
struct ArchitectureAnalyzer <: AbstractAnalyzer end
analyzer_name(::ImpactAnalyzer)="impact"
analyzer_name(::TestSelectionAnalyzer)="test_selection"
analyzer_name(::ArchitectureAnalyzer)="architecture"
requirements(::Union{ImpactAnalyzer,TestSelectionAnalyzer,ArchitectureAnalyzer})=[:definitions,:calls]
analyzer_name(::AbstractAnalyzer)=throw(ShenScopeError(:extension,"Analyzer must implement its name"))
requirements(::AbstractAnalyzer)=Symbol[]
analyze(::AbstractAnalyzer,state,request,ctx)=throw(ShenScopeError(:extension,"Analyzer must implement analyze"))

function analysis_seeds(state::ProjectState,request::AbstractDict)
    paths=String.(get(request,"paths",String[]));ids=SymbolId.(get(request,"symbols",String[]))
    length(paths)+length(ids)<=10000 || throw(ShenScopeError(:analysis,"Analysis input exceeds limit"))
    for path in paths
        facts=get(state.files,path,nothing);facts===nothing && throw(ShenScopeError(:analysis,"File is not indexed: "*path))
        append!(ids,(s.id for s in facts.symbols))
    end
    sort!(unique(ids))
end

function analyze(::ImpactAnalyzer,state::ProjectState,request::AbstractDict,ctx::RuntimeContext)
    authorize!(ctx,:read,"analysis.impact",ctx.root)
    lock(state.mutex) do
        seeds=analysis_seeds(state,request)
        result=graph_traverse(state,seeds;max_depth=get(request,"max_depth",8),max_nodes=get(request,"max_nodes",10000),ctx)
        seedset=Set(id.value for id in seeds)
        candidates=[merge(hit,Dict("score"=>hit["confidence"]/(1+hit["depth"]),"reason"=>"Reachable through recorded reverse relations"))
            for hit in result["hits"] if !(hit["symbol"]["id"] in seedset)]
        sort!(candidates;by=c->(-c["score"],c["symbol"]["id"]))
        Dict("analyzer"=>"impact","revision"=>state.revision,"candidates"=>candidates,"truncated"=>result["truncated"],
            "coverage"=>capability_dict(state.capabilities),"limitations"=>["Unresolved or dynamic calls can hide impact; reachability is evidence, not proof of runtime execution."])
    end
end
is_test_symbol(s::AbstractDict)=startswith(s["name"],"test_") || startswith(s["name"],"Test") ||
    occursin(r"(^|/)(test[s]?/|test_|[^/]+(_test\.go|\.(test|spec)\.[jt]sx?$))",s["location"]["file"])
function analyze(::TestSelectionAnalyzer,state::ProjectState,request::AbstractDict,ctx::RuntimeContext)
    impact=analyze(ImpactAnalyzer(),state,request,ctx)
    candidates=[merge(candidate,Dict("reason"=>"Test-named symbol reachable through recorded dependency relations"))
        for candidate in impact["candidates"] if is_test_symbol(candidate["symbol"])]
    lock(state.mutex) do
        for id in analysis_seeds(state,request)
            symbol=symbol_dict(state.symbols[id]);is_test_symbol(symbol) || continue
            push!(candidates,Dict("symbol"=>symbol,"depth"=>0,"confidence"=>1.0,"score"=>1.0,
                "evidence"=>String[],"reason"=>"Test-named symbol is directly changed"))
        end
    end
    Dict("analyzer"=>"test_selection","revision"=>impact["revision"],"candidates"=>candidates,"truncated"=>impact["truncated"],
        "limitations"=>["No coverage/test-run evidence is attached. These are test candidates; a full relevant test suite may still be necessary."])
end

function analyze(::ArchitectureAnalyzer,state::ProjectState,request::AbstractDict,ctx::RuntimeContext)
    authorize!(ctx,:read,"analysis.architecture",ctx.root)
    lock(state.mutex) do
        forward=Dict(path=>Set{String}() for path in keys(state.files));reverse=Dict(path=>Set{String}() for path in keys(state.files))
        for edge in values(state.relations)
            check_cancelled(ctx.cancellation);edge.kind in (:calls,:imports,:inherits,:implements) || continue
            src=state.symbols[edge.src].location.file;dst=state.symbols[edge.dst].location.file;src==dst && continue
            push!(forward[src],dst);push!(reverse[dst],src)
        end
        # Iterative Kosaraju avoids recursive stack growth on large dependency chains.
        visited=Set{String}();order=String[]
        for seed in sort!(collect(keys(forward)))
            seed in visited && continue;stack=Tuple{String,Bool}[(seed,false)]
            while !isempty(stack)
                check_cancelled(ctx.cancellation);node,finish=pop!(stack)
                if finish;push!(order,node);continue;end
                node in visited && continue;push!(visited,node);push!(stack,(node,true))
                for next in sort!(collect(forward[node]);rev=true);!(next in visited) && push!(stack,(next,false));end
            end
        end
        empty!(visited);cycles=Vector{String}[]
        for seed in reverse!(order)
            seed in visited && continue;component=String[];queue=[seed]
            while !isempty(queue)
                node=pop!(queue);node in visited && continue;push!(visited,node);push!(component,node)
                append!(queue,sort!(collect(reverse[node])))
            end
            length(component)>1 && push!(cycles,sort!(component))
        end
        sort!(cycles;by=first)
        hubs=sort!([Dict("file"=>path,"incoming_files"=>length(reverse[path]),"outgoing_files"=>length(forward[path])) for path in keys(forward)];
            by=x->(-x["incoming_files"],x["file"]))
        Dict("analyzer"=>"architecture","revision"=>state.revision,"cycles"=>cycles,"hubs"=>hubs[1:min(length(hubs),100)],
            "limitations"=>["File dependencies are derived from recorded relations; syntax heuristics and unresolved calls limit completeness."])
    end
end
