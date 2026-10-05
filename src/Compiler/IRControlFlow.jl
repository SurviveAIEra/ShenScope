function compiler_ir_blocks(statements,work::CompilerIRWork)
    total=length(statements);leaders=Set([1]);handlers=false
    for row in statements
        control=row["control"];index=row["id"]
        if control["kind"]!="fallthrough"
            union!(leaders,control["destinations"])
            index<total && push!(leaders,index+1)
        end
        if control["kind"]=="handler"
            handlers=true
            destination=control["exception_destination"]
            destination>0 && push!(leaders,destination)
        end
    end
    length(leaders)<=work.limits.max_blocks || throw(ShenScopeError(:capacity,"Compiler basic-block count exceeds limit"))
    starts=sort!(collect(leaders));blocks=Dict{String,Any}[];owners=zeros(Int,total)
    for (id,first) in enumerate(starts)
        last=id<length(starts) ? starts[id+1]-1 : total
        owners[first:last].=id
        push!(blocks,Dict("id"=>id,"first_statement"=>first,"last_statement"=>last,
            "successors"=>Int[],"predecessors"=>Int[]))
    end
    for block in blocks
        last=statements[block["last_statement"]]
        successors=sort!(unique([owners[d] for d in last["control"]["destinations"]]))
        block["successors"]=successors
        for destination in successors
            push!(blocks[destination]["predecessors"],block["id"])
        end
    end
    for block in blocks
        sort!(unique!(block["predecessors"]))
    end
    Dict("blocks"=>blocks,"statement_blocks"=>owners,"exception_handlers_present"=>handlers,
        "scope"=>"explicit normal control-flow edges; implicit exception propagation excluded",
        "normal_edges_complete"=>true,"all_exception_edges_complete"=>false)
end

function compiler_ir_reachable(blocks,work::CompilerIRWork;seeds=[1],reverse=false)
    visited=Set{Int}();queue=copy(seeds);position=1
    while position<=length(queue)
        node=queue[position];position+=1
        node in visited && continue
        1<=node<=length(blocks) || throw(ShenScopeError(:diagnostics,"Invalid compiler graph traversal seed"))
        push!(visited,node)
        adjacent=blocks[node][reverse ? "predecessors" : "successors"]
        compiler_ir_tick!(work;operations=1+length(adjacent))
        append!(queue,[next for next in adjacent if next ∉ visited])
    end
    visited
end

function compiler_ir_dominators(blocks,reachable::Set{Int},work::CompilerIRWork)
    domains=Dict(id=>(id==1 ? Set([1]) : copy(reachable)) for id in sort!(collect(reachable)))
    changed=true;rounds=0
    while changed
        changed=false;rounds+=1
        for id in sort!(collect(reachable))
            id==1 && continue
            predecessors=[p for p in blocks[id]["predecessors"] if p in reachable]
            isempty(predecessors) && throw(ShenScopeError(:diagnostics,"Reachable compiler block has no predecessor"))
            common=copy(domains[first(predecessors)])
            for predecessor in predecessors[2:end]
                compiler_ir_tick!(work;operations=1+length(common)+length(domains[predecessor]))
                intersect!(common,domains[predecessor])
            end
            push!(common,id)
            compiler_ir_tick!(work;operations=1+length(common))
            if common!=domains[id]
                domains[id]=common;changed=true
            end
        end
    end
    rows=Dict{String,Any}[]
    for id in sort!(collect(reachable))
        strict=setdiff(domains[id],Set([id]))
        candidates=sort!(collect(strict);by=p->(-length(domains[p]),p))
        push!(rows,Dict("block"=>id,"dominators"=>sort!(collect(domains[id])),
            "immediate_dominator"=>isempty(candidates) ? nothing : first(candidates)))
    end
    Dict("rows"=>rows,"fixed_point_rounds"=>rounds,"scope"=>"explicit normal paths from entry")
end

function compiler_ir_loops(blocks,dominators,work::CompilerIRWork)
    forward=Dict{String,Set{String}}(string(block["id"])=>Set{String}(string.(block["successors"])) for block in blocks)
    reverse=Dict{String,Set{String}}(string(block["id"])=>Set{String}(string.(block["predecessors"])) for block in blocks)
    groups=strongly_connected_groups(forward,reverse;
        checkpoint=()->compiler_ir_tick!(work;operations=1),max_edges=4*work.limits.max_blocks)
    cycles=Vector{Int}[]
    for group in groups
        members=sort!(parse.(Int,group))
        if length(members)>1 || first(members) in blocks[first(members)]["successors"]
            push!(cycles,members)
        end
    end
    sort!(cycles;by=first)
    domains=Dict(row["block"]=>Set(row["dominators"]) for row in dominators["rows"])
    back_edges=Dict{String,Int}[]
    for block in blocks, destination in block["successors"]
        compiler_ir_tick!(work;operations=1)
        haskey(domains,block["id"]) && destination in domains[block["id"]] &&
            push!(back_edges,Dict("source"=>block["id"],"destination"=>destination))
    end
    Dict("cycle_groups"=>cycles,"back_edges"=>back_edges,
        "termination_proven"=>false,"runtime_iterations_observed"=>false)
end

function compiler_ir_control_analysis(statements,work::CompilerIRWork)
    graph=compiler_ir_blocks(statements,work)
    blocks=graph["blocks"];reachable=compiler_ir_reachable(blocks,work)
    exits=[block["id"] for block in blocks if statements[block["last_statement"]]["control"]["kind"]=="return"]
    exit_paths=compiler_ir_reachable(blocks,work;seeds=exits,reverse=true)
    dominators=compiler_ir_dominators(blocks,reachable,work)
    merge(graph,Dict("reachable_blocks"=>sort!(collect(reachable)),
        "unreachable_blocks"=>sort!(setdiff(collect(eachindex(blocks)),collect(reachable))),
        "return_blocks"=>exits,"blocks_on_explicit_exit_paths"=>sort!(collect(exit_paths)),
        "dominators"=>dominators,"loops"=>compiler_ir_loops(blocks,dominators,work)))
end
