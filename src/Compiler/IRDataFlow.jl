function compiler_ir_state_copy(state::Dict{Int,Set{String}})
    Dict(slot=>copy(definitions) for (slot,definitions) in state)
end

function compiler_ir_state_merge!(target,source,work::CompilerIRWork)
    for (slot,definitions) in source
        compiler_ir_tick!(work;operations=1+length(definitions))
        union!(get!(Set{String},target,slot),definitions)
    end
    target
end

function compiler_ir_definition_id(statement,slot,reset=false)
    (reset ? "reset:" : "definition:")*string(statement)*":"*string(slot)
end

function compiler_ir_transfer!(state,statement,work::CompilerIRWork)
    for slot in statement["writes_slots"]
        compiler_ir_tick!(work;operations=1)
        state[slot]=Set([compiler_ir_definition_id(statement["id"],slot)])
    end
    for slot in statement["reset_slots"]
        compiler_ir_tick!(work;operations=1)
        state[slot]=Set([compiler_ir_definition_id(statement["id"],slot,true)])
    end
    state
end

function compiler_ir_slot_flow(statements,graph,slots,argument_slots,work::CompilerIRWork)
    blocks=graph["blocks"];reachable=Set(graph["reachable_blocks"])
    arguments=compiler_ir_integer(argument_slots,"argument slot count",0,length(slots))
    definitions=Dict{String,Any}[]
    entry=Dict{Int,Set{String}}()
    for slot in eachindex(slots)
        kind=slot<=arguments ? "argument" : "uninitialized"
        id=kind*":"*string(slot)
        entry[slot]=Set([id])
        push!(definitions,Dict("id"=>id,"slot"=>slot,"statement"=>0,"block"=>0,"kind"=>kind))
    end
    owners=graph["statement_blocks"]
    for row in statements
        for slot in row["writes_slots"]
            push!(definitions,Dict("id"=>compiler_ir_definition_id(row["id"],slot),
                "slot"=>slot,"statement"=>row["id"],"block"=>owners[row["id"]],"kind"=>"assignment"))
        end
        for slot in row["reset_slots"]
            push!(definitions,Dict("id"=>compiler_ir_definition_id(row["id"],slot,true),
                "slot"=>slot,"statement"=>row["id"],"block"=>owners[row["id"]],"kind"=>"reset"))
        end
    end
    incoming=[Dict{Int,Set{String}}() for _ in blocks]
    outgoing=[Dict{Int,Set{String}}() for _ in blocks]
    changed=true;rounds=0
    while changed
        changed=false;rounds+=1
        for id in sort!(collect(reachable))
            state=Dict{Int,Set{String}}()
            id==1 && compiler_ir_state_merge!(state,entry,work)
            for predecessor in blocks[id]["predecessors"]
                predecessor in reachable && compiler_ir_state_merge!(state,outgoing[predecessor],work)
            end
            incoming[id]=state
            result=compiler_ir_state_copy(state)
            for index in blocks[id]["first_statement"]:blocks[id]["last_statement"]
                compiler_ir_transfer!(result,statements[index],work)
            end
            if result!=outgoing[id]
                outgoing[id]=result;changed=true
            end
        end
    end
    reads=Dict{String,Any}[]
    kind_by_id=Dict(row["id"]=>row["kind"] for row in definitions)
    for block in blocks
        id=block["id"];state=compiler_ir_state_copy(incoming[id])
        for index in block["first_statement"]:block["last_statement"]
            row=statements[index]
            for slot in row["reads_slots"]
                candidates=sort!(collect(get(state,slot,Set{String}())))
                compiler_ir_tick!(work;operations=1+length(candidates))
                undefined=any(definition->kind_by_id[definition] in ("uninitialized","reset"),candidates)
                push!(reads,Dict("statement"=>index,"slot"=>slot,"block"=>id,
                    "possible_definitions"=>candidates,"reachable_from_entry"=>id in reachable,
                    "possibly_uninitialized"=>undefined,"runtime_value_observed"=>false))
            end
            compiler_ir_transfer!(state,row,work)
        end
    end
    block_states=[Dict("block"=>id,
        "incoming"=>[Dict("slot"=>slot,"definitions"=>sort!(collect(values))) for (slot,values) in sort!(collect(incoming[id]);by=first)],
        "outgoing"=>[Dict("slot"=>slot,"definitions"=>sort!(collect(values))) for (slot,values) in sort!(collect(outgoing[id]);by=first)]) for id in eachindex(blocks)]
    Dict("definitions"=>definitions,"reads"=>reads,"block_states"=>block_states,
        "fixed_point_rounds"=>rounds,"scope"=>"possible local-slot definitions on explicit normal paths; no heap alias or execution analysis")
end

function compiler_ir_ssa_flow(statements,work::CompilerIRWork)
    edges=Dict{String,Int}[]
    for row in statements, source in row["uses_ssa"]
        compiler_ir_tick!(work;operations=1)
        push!(edges,Dict("definition"=>source,"use"=>row["id"]))
    end
    Dict("edges"=>edges,"scope"=>"references present in compiler IR; not a runtime trace")
end

function compiler_ir_witness(graph,start::Int,finish::Int,work::CompilerIRWork)
    blocks=graph["blocks"]
    1<=start<=length(blocks) && 1<=finish<=length(blocks) ||
        throw(ShenScopeError(:diagnostics,"Compiler witness endpoints exceed graph bounds"))
    queue=[start];position=1;parents=Dict(start=>0)
    while position<=length(queue)
        current=queue[position];position+=1
        if current==finish
            path=Int[];node=current
            while node!=0
                push!(path,node);node=parents[node]
            end
            return reverse(path)
        end
        for next in blocks[current]["successors"]
            compiler_ir_tick!(work;operations=1)
            if !haskey(parents,next)
                parents[next]=current;push!(queue,next)
            end
        end
    end
    nothing
end
