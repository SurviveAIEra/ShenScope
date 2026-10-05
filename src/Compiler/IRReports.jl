function compiler_ir_slots(code::Core.CodeInfo)
    rows=Dict{String,Any}[]
    for (id,name) in enumerate(code.slotnames)
        inferred=code.slottypes isa AbstractVector && id<=length(code.slottypes) ? code.slottypes[id] : Any
        push!(rows,Dict("id"=>id,"name"=>cliptext(string(name),256),"inferred_type"=>compiler_ir_type(inferred)))
    end
    rows
end

function compiler_ir_method_graph(code::Core.CodeInfo,identity::AbstractDict,root::String;
        limits=CompilerIRLimits())
    work=CompilerIRWork(limits)
    statements=compiler_ir_statements(code,work,root)
    slots=compiler_ir_slots(code)
    graph=compiler_ir_control_analysis(statements,work)
    flow=compiler_ir_slot_flow(statements,graph,slots,identity["argument_slots"],work)
    ssa=compiler_ir_ssa_flow(statements,work)
    findings=compiler_ir_findings(statements,slots,graph,flow,work)
    calls=Dict{String,Any}[]
    for row in statements, (ordinal,call) in enumerate(row["calls"])
        push!(calls,merge(call,Dict("id"=>"call:"*string(row["id"])*":"*string(ordinal),
            "statement"=>row["id"],"source"=>row["source"])))
    end
    Dict("identity"=>Dict(identity),"statements"=>statements,"slots"=>slots,
        "control_flow"=>graph,"slot_flow"=>flow,"ssa_flow"=>ssa,"calls"=>calls,
        "return_type"=>compiler_ir_type(code.rettype),"findings"=>findings,
        "inference_world"=>Dict("minimum"=>string(code.min_world),"maximum"=>string(code.max_world)),
        "statistics"=>Dict("statements"=>length(statements),"slots"=>length(slots),
            "blocks"=>length(graph["blocks"]),"normal_edges"=>sum(length(row["successors"]) for row in graph["blocks"]),
            "ssa_edges"=>length(ssa["edges"]),"slot_reads"=>length(flow["reads"]),
            "calls"=>length(calls),"operand_nodes"=>work.operands,"flow_operations"=>work.flow_operations),
        "compiler_inferred"=>true,"runtime_execution_observed"=>false)
end

function compiler_ir_report(name::AbstractString;limits=CompilerIRLimits())
    target=compiler_target(name);root=runtime_core_root();started=time_ns()
    # This entry accepts only the fixed trusted target table. The public worker
    # caller checks permissions and fingerprints before and after compilation.
    ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,
        :edit=>Deny,:process=>Deny,:network=>Deny,:persistence=>Deny,:dynamic=>Deny)))
    snapshot=runtime_source_snapshot(ctx;root)
    selected=which(target.callable,target.arguments)
    identity=compiler_ir_method_identity(selected,snapshot)
    entries=Base.code_typed(target.callable,target.arguments;optimize=false)
    graphs=Dict{String,Any}[]
    for entry in entries[1:min(length(entries),8)]
        code=entry.first
        definition=code.parent isa Core.MethodInstance ? code.parent.def : selected
        definition isa Method || throw(ShenScopeError(:diagnostics,"Compiler graph has no method identity"))
        graph_identity=compiler_ir_method_identity(definition,snapshot)
        graph_identity["signature"]==identity["signature"] ||
            throw(ShenScopeError(:diagnostics,"Compiler returned a different trusted method"))
        push!(graphs,compiler_ir_method_graph(code,graph_identity,root;limits))
    end
    effects=compiler_ir_effects(target.callable,target.arguments)
    runtime_source_snapshot(ctx;root).fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Core source changed during compiler analysis"))
    report=Dict("schema"=>COMPILER_IR_SCHEMA,"target"=>target.name,"arguments"=>string(target.arguments),
        "runtime"=>Dict("julia_version"=>string(Base.VERSION),"machine"=>string(Sys.MACHINE),
            "observed_world"=>string(Base.get_world_counter())),
        "source"=>Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)),
        "methods"=>graphs,"methods_observed"=>length(entries),"methods_truncated"=>length(entries)>8,
        "effects"=>effects,"elapsed_seconds"=>(time_ns()-started)/1e9,
        "limits"=>Dict(string(field)=>getfield(limits,field) for field in fieldnames(CompilerIRLimits)),
        "scope"=>"fixed trusted Core methods; unoptimized compiler IR; no project loading or target execution")
    report["report_sha256"]=digest(canonical(report))
    bounded_canonical_json(report;maximum=COMPILER_IR_MAX_BYTES)
    report
end

function compiler_ir_compare(left::AbstractDict,right::AbstractDict)
    get(left,"schema",nothing)==COMPILER_IR_SCHEMA && get(right,"schema",nothing)==COMPILER_IR_SCHEMA ||
        throw(ShenScopeError(:diagnostics,"Compiler report schemas do not match"))
    comparable=left["target"]==right["target"] && left["arguments"]==right["arguments"] &&
        left["runtime"]["julia_version"]==right["runtime"]["julia_version"] &&
        left["runtime"]["machine"]==right["runtime"]["machine"]
    comparable || throw(ShenScopeError(:diagnostics,"Compare the same trusted target, arguments and compiler platform"))
    summaries=Dict{String,Any}[]
    for index in 1:min(length(left["methods"]),length(right["methods"]))
        before=left["methods"][index];after=right["methods"][index]
        push!(summaries,Dict("method"=>after["identity"]["signature"],
            "source_changed"=>before["identity"]["source_sha256"]!=after["identity"]["source_sha256"],
            "return_type_before"=>before["return_type"],"return_type_after"=>after["return_type"],
            "statistics_delta"=>Dict(key=>after["statistics"][key]-before["statistics"][key] for key in keys(before["statistics"]))))
    end
    Dict("target"=>left["target"],"source_changed"=>left["source"]["fingerprint"]!=right["source"]["fingerprint"],
        "methods_before"=>length(left["methods"]),"methods_after"=>length(right["methods"]),
        "methods"=>summaries,"performance_change_proven"=>false,"runtime_behavior_change_proven"=>false)
end
