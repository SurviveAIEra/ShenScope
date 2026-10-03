function graph_search(state::ProjectState,query::AbstractString;kind=nothing,path=nothing,limit=50,offset=0)
    1<=limit<=1000 && 0<=offset<=100000 && ncodeunits(query)<=4096 || throw(ShenScopeError(:graph,"Invalid graph query limits"))
    terms=unique(lexical_tokens(query));needle=lowercase(query)
    lock(state.mutex) do
        results=Tuple{Float64,CodeSymbol}[]
        for symbol in values(state.symbols)
            kind!==nothing && symbol.kind!=Symbol(kind) && continue
            path!==nothing && !startswith(symbol.location.file,String(path)) && continue
            name=lowercase(symbol.name);qualified=lowercase(symbol.qualified_name)
            tokens=Set(lexical_tokens(symbol.name*" "*symbol.qualified_name*" "*symbol.location.file))
            score=isempty(terms) ? 1.0 : sum(term in tokens for term in terms)/length(terms)
            name==needle && (score+=3);startswith(name,needle) && !isempty(needle) && (score+=1)
            occursin(needle,qualified) && !isempty(needle) && (score+=0.5)
            score>0 || continue;symbol.kind==:file && (score*=0.5)
            push!(results,(score,symbol))
        end
        sort!(results;by=r->(-r[1],r[2].id.value))
        selected=results[min(offset+1,length(results)+1):min(offset+limit,length(results))]
        Dict("revision"=>state.revision,"total"=>length(results),"offset"=>offset,"next_offset"=>offset+limit<length(results) ? offset+limit : nothing,
            "symbols"=>[merge(symbol_dict(symbol),Dict("score"=>score)) for (score,symbol) in selected])
    end
end

function graph_traverse(state::ProjectState,seeds::AbstractVector;direction=:reverse,
        kinds=[:calls,:inherits,:implements,:imports,:references],max_depth=8,max_nodes=10000,ctx=nothing)
    direction in (:forward,:reverse) && 0<=max_depth<=32 && 1<=max_nodes<=100000 || throw(ShenScopeError(:graph,"Invalid traversal limits"))
    length(seeds)<=max_nodes || throw(ShenScopeError(:graph,"Traversal seeds exceed limit"))
    lock(state.mutex) do
        ids=SymbolId[id isa SymbolId ? id : SymbolId(id) for id in seeds]
        all(id->haskey(state.symbols,id),ids) || throw(ShenScopeError(:graph,"Unknown traversal seed"))
        queue=sort!(unique(ids));depth=Dict(id=>0 for id in queue);confidence=Dict(id=>1.0 for id in queue)
        parent=Dict{SymbolId,Tuple{SymbolId,String}}();cursor=1;truncated=false
        while cursor<=length(queue)
            ctx!==nothing && check_cancelled(ctx.cancellation)
            id=queue[cursor];cursor+=1;depth[id]>=max_depth && continue
            adjacency=direction==:reverse ? state.reverse : state.forward
            for edge_id in sort!(collect(get(adjacency,id,Set{String}())))
                edge=state.relations[edge_id];edge.kind in kinds || continue
                next=direction==:reverse ? edge.src : edge.dst
                haskey(depth,next) && continue
                if length(queue)>=max_nodes;truncated=true;continue;end
                depth[next]=depth[id]+1;confidence[next]=confidence[id]*edge.confidence;parent[next]=(id,edge_id);push!(queue,next)
            end
        end
        hits=Dict{String,Any}[]
        for id in queue
            evidence=String[];current=id
            while haskey(parent,current) && length(evidence)<32
                current,edge=parent[current];push!(evidence,edge)
            end
            push!(hits,Dict("symbol"=>symbol_dict(state.symbols[id]),"depth"=>depth[id],"confidence"=>confidence[id],"evidence"=>reverse(evidence)))
        end
        Dict("revision"=>state.revision,"direction"=>String(direction),"truncated"=>truncated,"hits"=>hits)
    end
end

function project_status(state::ProjectState)
    lock(state.mutex) do
        unresolved=count(ref->resolve_reference(state,ref)===nothing,(ref for facts in values(state.files) for ref in facts.references))
        Dict("backend"=>state.backend,"revision"=>state.revision,"files"=>length(state.files),"symbols"=>length(state.symbols),
            "relations"=>length(state.relations),"unresolved_syntax_calls"=>unresolved,
            "capabilities"=>capability_dict(state.capabilities),"persistent_bytes"=>state.journal_bytes)
    end
end
