function compiler_ir_callee(value)
    if value isa GlobalRef
        return Dict("kind"=>"global_binding","module"=>cliptext(string(value.mod),256),
            "name"=>cliptext(string(value.name),256),"runtime_dispatch_confirmed"=>false)
    elseif value isa Core.MethodInstance
        definition=value.def
        return Dict("kind"=>"inferred_invoke","module"=>definition isa Method ? string(definition.module) : nothing,
            "name"=>definition isa Method ? string(definition.name) : nothing,
            "signature"=>cliptext(string(value.specTypes),2048),"runtime_dispatch_confirmed"=>false)
    elseif value isa Core.Const && value.val isa Function
        return Dict("kind"=>"constant_callable","module"=>cliptext(string(parentmodule(value.val)),256),
            "name"=>cliptext(string(nameof(value.val)),256),"runtime_dispatch_confirmed"=>false)
    elseif value isa Core.SSAValue
        return Dict("kind"=>"ssa_callable","ssa"=>Int(value.id),"runtime_dispatch_confirmed"=>false)
    elseif value isa Core.SlotNumber || value isa Core.Argument
        return Dict("kind"=>"slot_callable","slot"=>value isa Core.SlotNumber ? Int(value.id) : Int(value.n),
            "runtime_dispatch_confirmed"=>false)
    end
    Dict("kind"=>"unresolved_callable","type"=>cliptext(string(typeof(value)),256),"runtime_dispatch_confirmed"=>false)
end

function compiler_ir_operand(value,work::CompilerIRWork,ssa,slots,calls;
        depth=0,statement_count=0,slot_count=0,read_reference=true)
    compiler_ir_tick!(work;depth)
    if value isa Core.SSAValue
        id=compiler_ir_integer(value.id,"SSA reference",1,statement_count)
        read_reference && push!(ssa,id)
        return Dict("kind"=>"ssa","id"=>id)
    elseif value isa Core.SlotNumber || value isa Core.Argument
        id=compiler_ir_integer(value isa Core.SlotNumber ? value.id : value.n,"slot reference",1,slot_count)
        read_reference && push!(slots,id)
        return Dict("kind"=>value isa Core.Argument ? "argument" : "slot","id"=>id)
    elseif value isa GlobalRef
        return Dict("kind"=>"global","module"=>cliptext(string(value.mod),256),"name"=>cliptext(string(value.name),256))
    elseif value isa Expr
        length(value.args)<=256 || throw(ShenScopeError(:capacity,"Compiler expression argument count exceeds limit"))
        value.head in (:call,:invoke,:foreigncall) && !isempty(value.args) &&
            push!(calls,merge(compiler_ir_callee(first(value.args)),Dict("operation"=>String(value.head))))
        arguments=Any[]
        for (index,argument) in enumerate(value.args)
            used=read_reference && !(value.head==:(=) && index==1)
            push!(arguments,compiler_ir_operand(argument,work,ssa,slots,calls;
                depth=depth+1,statement_count,slot_count,read_reference=used))
        end
        return Dict("kind"=>"expression","head"=>String(value.head),"arguments"=>arguments)
    elseif value isa Core.PhiNode || value isa Core.PhiCNode
        length(value.values)<=256 || throw(ShenScopeError(:capacity,"Compiler phi input count exceeds limit"))
        values=Any[]
        for index in eachindex(value.values)
            if isassigned(value.values,index)
                push!(values,compiler_ir_operand(value.values[index],work,ssa,slots,calls;
                    depth=depth+1,statement_count,slot_count,read_reference))
            else
                push!(values,Dict("kind"=>"undefined_phi_input"))
            end
        end
        result=Dict{String,Any}("kind"=>value isa Core.PhiNode ? "phi" : "exception_phi","values"=>values)
        value isa Core.PhiNode && (result["predecessor_statements"]=[compiler_ir_integer(x,"phi predecessor",0,statement_count) for x in value.edges])
        return result
    elseif value isa Core.ReturnNode || value isa Core.UpsilonNode
        inner=isdefined(value,:val) ? compiler_ir_operand(value.val,work,ssa,slots,calls;
            depth=depth+1,statement_count,slot_count,read_reference) : Dict("kind"=>"undefined_value")
        return Dict("kind"=>value isa Core.ReturnNode ? "return" : "exception_value","value"=>inner)
    elseif value isa Core.GotoIfNot
        return Dict("kind"=>"conditional_branch","condition"=>compiler_ir_operand(value.cond,work,ssa,slots,calls;
            depth=depth+1,statement_count,slot_count,read_reference),"destination"=>Int(value.dest))
    elseif value isa Core.GotoNode
        return Dict("kind"=>"jump","destination"=>Int(value.label))
    elseif value isa Core.NewvarNode
        return Dict("kind"=>"reset_slot","slot"=>compiler_ir_integer(value.slot.id,"reset slot",1,slot_count))
    elseif value isa Core.EnterNode
        scope=isdefined(value,:scope) ? compiler_ir_operand(value.scope,work,ssa,slots,calls;
            depth=depth+1,statement_count,slot_count,read_reference) : Dict("kind"=>"undefined_value")
        return Dict("kind"=>"exception_handler","destination"=>Int(value.catch_dest),"scope"=>scope,"scope_value_exposed"=>false)
    elseif value isa QuoteNode || value isa Core.Const
        # Constants can contain arbitrary objects; never invoke their show methods.
        item=value isa QuoteNode ? value.value : value.val
        return Dict("kind"=>"constant","type"=>cliptext(string(typeof(item)),256),"value_exposed"=>false)
    elseif value isa Symbol
        return Dict("kind"=>"symbol","name"=>cliptext(string(value),256))
    elseif value isa Bool || value===nothing
        return Dict("kind"=>"literal","value"=>value)
    elseif value isa Integer
        return Dict("kind"=>"integer_literal","representation"=>cliptext(string(value),128))
    elseif value isa AbstractFloat
        return Dict("kind"=>"float_literal","finite"=>isfinite(value),"representation"=>cliptext(string(value),128))
    end
    Dict("kind"=>"opaque_literal","type"=>cliptext(string(typeof(value)),256),"value_exposed"=>false)
end

function compiler_ir_control(value,index,total)
    if value isa Core.GotoNode
        return Dict("kind"=>"jump","destinations"=>[compiler_ir_integer(value.label,"jump destination",1,total)])
    elseif value isa Core.GotoIfNot
        destinations=[compiler_ir_integer(value.dest,"branch destination",1,total)]
        index<total && push!(destinations,index+1)
        return Dict("kind"=>"branch","destinations"=>sort!(unique(destinations)))
    elseif value isa Core.ReturnNode
        return Dict("kind"=>"return","destinations"=>Int[])
    elseif value isa Core.EnterNode
        handler=compiler_ir_integer(value.catch_dest,"handler destination",0,total)
        return Dict("kind"=>"handler","destinations"=>index<total ? [index+1] : Int[],"exception_destination"=>handler)
    end
    Dict("kind"=>"fallthrough","destinations"=>index<total ? [index+1] : Int[])
end

function compiler_ir_statements(code::Core.CodeInfo,work::CompilerIRWork,root::String)
    total=length(code.code)
    1<=total<=work.limits.max_statements || throw(ShenScopeError(:capacity,"Compiler method statement count exceeds limit"))
    slot_count=length(code.slotnames)
    slot_count<=work.limits.max_statements || throw(ShenScopeError(:capacity,"Compiler method slot count exceeds limit"))
    rows=Dict{String,Any}[]
    for (index,value) in enumerate(code.code)
        ssa=Int[];slots=Int[];calls=Dict{String,Any}[];writes=Int[];resets=Int[]
        if value isa Expr && value.head==:(=) && !isempty(value.args) && first(value.args) isa Core.SlotNumber
            push!(writes,compiler_ir_integer(first(value.args).id,"assignment slot",1,slot_count))
        elseif value isa Core.NewvarNode
            push!(resets,compiler_ir_integer(value.slot.id,"reset slot",1,slot_count))
        end
        operand=compiler_ir_operand(value,work,ssa,slots,calls;statement_count=total,slot_count)
        control=compiler_ir_control(value,index,total)
        inferred=code.ssavaluetypes isa AbstractVector && index<=length(code.ssavaluetypes) ? code.ssavaluetypes[index] : Any
        produces=control["kind"]=="fallthrough" && !(value isa Core.NewvarNode) &&
            !(value isa Expr && value.head in (:meta,:leave,:pop_exception))
        push!(rows,Dict("id"=>index,"opcode"=>value isa Expr ? String(value.head) : string(nameof(typeof(value))),
            "kind"=>string(typeof(value)),"inferred_type"=>compiler_ir_type(inferred),"produces_value"=>produces,
            "uses_ssa"=>sort!(unique(ssa)),"reads_slots"=>sort!(unique(slots)),"writes_slots"=>writes,
            "reset_slots"=>resets,"calls"=>calls,"source"=>compiler_ir_location(code,index,root),
            "operand"=>operand,"control"=>control))
    end
    rows
end
