function compiler_ir_effects(callable::Function,arguments::Type)
    predicates=(:consistent,:effect_free,:nothrow,:terminates,:notaskstate,
        :inaccessiblememonly,:noub,:nonoverlayed,:nortcall)
    result=Dict{String,Any}("experimental"=>true,"safety_boundary"=>false,
        "runtime_side_effects_observed"=>false,"julia_version"=>string(Base.VERSION))
    if !isdefined(Base,:infer_effects)
        return merge(result,Dict("available"=>false,"reason"=>"Effect inference is unavailable in this Julia runtime"))
    end
    effects=try
        Base.infer_effects(callable,arguments)
    catch
        return merge(result,Dict("available"=>false,"reason"=>"Compiler effect inference did not produce a report"))
    end
    guarantees=Dict{String,Any}();encoded=Dict{String,Any}()
    for property in predicates
        predicate=Symbol("is_",property)
        proven=isdefined(Core.Compiler,predicate) ? getfield(Core.Compiler,predicate)(effects) : nothing
        proven===nothing || proven isa Bool || throw(ShenScopeError(:diagnostics,"Unexpected compiler effect predicate"))
        guarantees[String(property)]=proven
        if hasfield(typeof(effects),property)
            value=getfield(effects,property)
            encoded[String(property)]=value isa Bool ? value : value isa UInt8 ? Int(value) : nothing
        end
    end
    merge(result,Dict("available"=>true,"proven_properties"=>guarantees,"version_specific_encoding"=>encoded,
        "interpretation"=>"A false predicate means no unconditional compiler guarantee; it is not proof of a side effect, nontermination or vulnerability."))
end

function compiler_ir_findings(statements,slots,graph,flow,work::CompilerIRWork)
    all=Dict{String,Any}[]
    for row in statements
        type=row["inferred_type"]
        if row["produces_value"] && type["classification"] in ("any","nonconcrete","compiler_lattice_value")
            push!(all,Dict("kind"=>"inferred_value_not_concrete","severity"=>"information",
                "statement"=>row["id"],"slot"=>nothing,"evidence"=>type,
                "message"=>"This inferred value is not an ordinary concrete type; runtime cost has not been measured."))
        end
        for call in row["calls"]
            if call["kind"] in ("ssa_callable","slot_callable","unresolved_callable") || call["operation"]=="foreigncall"
                push!(all,Dict("kind"=>"call_requires_additional_evidence","severity"=>"information",
                    "statement"=>row["id"],"slot"=>nothing,"evidence"=>call,
                    "message"=>"No executed callee or runtime behavior is established by this call record."))
            end
        end
    end
    for read in flow["reads"]
        read["reachable_from_entry"] && read["possibly_uninitialized"] || continue
        push!(all,Dict("kind"=>"possible_uninitialized_local","severity"=>"information",
            "statement"=>read["statement"],"slot"=>read["slot"],"evidence"=>read,
            "message"=>"An explicit normal path includes an uninitialized/reset local definition; exception and heap effects are excluded."))
    end
    for block in graph["unreachable_blocks"]
        push!(all,Dict("kind"=>"unreachable_in_normal_graph","severity"=>"information",
            "statement"=>graph["blocks"][block]["first_statement"],"slot"=>nothing,
            "evidence"=>Dict("block"=>block),
            "message"=>"This block is unreachable through explicit normal edges; it may be an exception handler."))
    end
    retained=all[1:min(length(all),work.limits.max_findings)]
    Dict("items"=>retained,"total"=>length(all),"truncated"=>length(retained)<length(all),
        "proof_of_runtime_failure"=>false)
end
