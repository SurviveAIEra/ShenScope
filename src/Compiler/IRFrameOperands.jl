function compiler_ir_validate_operand(value,work,ssa,slots;total,slot_count,depth=0,read_reference=true)
    compiler_ir_tick!(work;depth)
    value isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler operand must be an object"))
    kind=get(value,"kind",nothing)
    if kind in ("ssa","slot","argument")
        compiler_ir_fields(value,["kind","id"],"reference operand")
        maximum=kind=="ssa" ? total : slot_count
        id=compiler_ir_integer(value["id"],"operand reference",1,maximum)
        read_reference && push!(kind=="ssa" ? ssa : slots,id)
    elseif kind=="expression"
        compiler_ir_fields(value,["kind","head","arguments"],"expression operand")
        head=compiler_ir_text(value["head"],"expression head",256)
        args=value["arguments"]
        args isa AbstractVector && length(args)<=256 || throw(ShenScopeError(:diagnostics,"Invalid compiler expression arguments"))
        for (index,argument) in enumerate(args)
            compiler_ir_validate_operand(argument,work,ssa,slots;total,slot_count,depth=depth+1,
                read_reference=read_reference && !(head=="=" && index==1))
        end
    elseif kind in ("phi","exception_phi")
        compiler_ir_fields(value,kind=="phi" ? ["kind","values","predecessor_statements"] : ["kind","values"],"phi operand")
        values=value["values"]
        values isa AbstractVector && length(values)<=256 || throw(ShenScopeError(:diagnostics,"Invalid compiler phi inputs"))
        for item in values
            compiler_ir_validate_operand(item,work,ssa,slots;total,slot_count,depth=depth+1,read_reference)
        end
        if kind=="phi"
            edges=value["predecessor_statements"]
            edges isa AbstractVector && length(edges)==length(values) || throw(ShenScopeError(:diagnostics,"Compiler phi predecessor count disagrees"))
            for edge in edges
                compiler_ir_integer(edge,"phi predecessor",0,total)
            end
        end
    elseif kind in ("return","exception_value")
        compiler_ir_fields(value,["kind","value"],"result operand")
        compiler_ir_validate_operand(value["value"],work,ssa,slots;total,slot_count,depth=depth+1,read_reference)
    elseif kind=="conditional_branch"
        compiler_ir_fields(value,["kind","condition","destination"],"branch operand")
        compiler_ir_integer(value["destination"],"operand branch destination",1,total)
        compiler_ir_validate_operand(value["condition"],work,ssa,slots;total,slot_count,depth=depth+1,read_reference)
    elseif kind=="jump"
        compiler_ir_fields(value,["kind","destination"],"jump operand")
        compiler_ir_integer(value["destination"],"operand jump destination",1,total)
    elseif kind=="reset_slot"
        compiler_ir_fields(value,["kind","slot"],"reset operand")
        compiler_ir_integer(value["slot"],"operand reset slot",1,slot_count)
    elseif kind=="exception_handler"
        compiler_ir_fields(value,["kind","destination","scope","scope_value_exposed"],"handler operand")
        compiler_ir_integer(value["destination"],"operand handler destination",0,total)
        value["scope_value_exposed"]===false || throw(ShenScopeError(:diagnostics,"Compiler handler exposes a value"))
        compiler_ir_validate_operand(value["scope"],work,ssa,slots;total,slot_count,depth=depth+1,read_reference)
    elseif kind in ("constant","opaque_literal")
        compiler_ir_fields(value,["kind","type","value_exposed"],"constant operand")
        compiler_ir_text(value["type"],"constant type",256)
        value["value_exposed"]===false || throw(ShenScopeError(:diagnostics,"Compiler constant exposes an object value"))
    elseif kind=="literal"
        compiler_ir_fields(value,["kind","value"],"literal operand")
        value["value"]===nothing || value["value"] isa Bool || throw(ShenScopeError(:diagnostics,"Invalid compiler literal value"))
    elseif kind in ("integer_literal","float_literal")
        compiler_ir_fields(value,kind=="float_literal" ? ["kind","finite","representation"] : ["kind","representation"],"numeric operand")
        compiler_ir_text(value["representation"],"numeric representation",128)
        kind=="float_literal" && !(value["finite"] isa Bool) && throw(ShenScopeError(:diagnostics,"Invalid compiler numeric flag"))
    elseif kind=="global"
        compiler_ir_fields(value,["kind","module","name"],"global operand")
        compiler_ir_text(value["module"],"global module",256)
        compiler_ir_text(value["name"],"global name",256)
    elseif kind=="symbol"
        compiler_ir_fields(value,["kind","name"],"symbol operand")
        compiler_ir_text(value["name"],"symbol name",256)
    elseif kind in ("undefined_phi_input","undefined_value")
        compiler_ir_fields(value,["kind"],"undefined operand")
    else
        throw(ShenScopeError(:diagnostics,"Unknown compiler operand kind"))
    end
end

function compiler_ir_validate_call(value,total,slot_count)
    kind=get(value,"kind",nothing)
    common=["kind","operation","runtime_dispatch_confirmed"]
    fields=kind in ("global_binding","constant_callable") ? ["module","name"] :
        kind=="inferred_invoke" ? ["module","name","signature"] :
        kind=="ssa_callable" ? ["ssa"] : kind=="slot_callable" ? ["slot"] :
        kind=="unresolved_callable" ? ["type"] : nothing
    fields===nothing && throw(ShenScopeError(:diagnostics,"Unknown compiler call kind"))
    compiler_ir_fields(value,vcat(common,fields),"call")
    value["runtime_dispatch_confirmed"]===false && value["operation"] in ("call","invoke","foreigncall") ||
        throw(ShenScopeError(:diagnostics,"Compiler call overstates runtime evidence"))
    for key in ("module","name")
        haskey(value,key) || continue
        value[key]===nothing && kind=="inferred_invoke" && continue
        compiler_ir_text(value[key],"callee "*key,256)
    end
    haskey(value,"signature") && compiler_ir_text(value["signature"],"callee signature",2048)
    haskey(value,"type") && compiler_ir_text(value["type"],"callee type",256)
    haskey(value,"ssa") && compiler_ir_integer(value["ssa"],"callee SSA",1,total)
    haskey(value,"slot") && compiler_ir_integer(value["slot"],"callee slot",1,slot_count)
end
