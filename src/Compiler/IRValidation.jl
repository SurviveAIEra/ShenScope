function compiler_ir_fields(value,fields,label)
    value isa AbstractDict && Set(keys(value))==Set(fields) ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler "*label*" fields"))
    value
end

function compiler_ir_text(value,label,maximum=2048)
    value isa String && isvalid(value) && 1<=ncodeunits(value)<=maximum && !occursin('\0',value) ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler "*label))
    value
end

function compiler_ir_indices(value,label,maximum;sorted=true)
    value isa AbstractVector && length(value)<=maximum ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler "*label*" collection"))
    indices=[compiler_ir_integer(item,label,1,maximum) for item in value]
    length(unique(indices))==length(indices) && (!sorted || issorted(indices)) ||
        throw(ShenScopeError(:diagnostics,"Compiler "*label*" values must be unique and ordered"))
    indices
end

function compiler_ir_validate_type(value)
    compiler_ir_fields(value,["type","classification","concrete","bottom","constant_value_exposed"],"type summary")
    compiler_ir_text(value["type"],"inferred type",512)
    value["classification"] in ("constant","bottom","any","concrete","small_concrete_union","nonconcrete","compiler_lattice_value") &&
        value["concrete"] isa Bool && value["bottom"] isa Bool && value["constant_value_exposed"]===false ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler type classification"))
    value["bottom"]==(value["classification"]=="bottom") ||
        throw(ShenScopeError(:diagnostics,"Compiler bottom-type summary disagrees"))
    value["classification"] in ("constant","concrete") && !value["concrete"] &&
        throw(ShenScopeError(:diagnostics,"Compiler concrete-type summary disagrees"))
end

function compiler_ir_validate_location(value,snapshot)
    compiler_ir_fields(value,["file","line","scope"],"source location")
    if value["scope"]=="unknown"
        value["file"]===nothing && value["line"]===nothing || throw(ShenScopeError(:diagnostics,"Unknown compiler source has coordinates"))
    elseif value["scope"] in ("core","external")
        file=compiler_ir_text(value["file"],"source filename",512)
        compiler_ir_integer(value["line"],"source line",0,10_000_000)
        if value["scope"]=="core"
            file in getfield.(snapshot.files,:path) && startswith(file,"src/") ||
                throw(ShenScopeError(:diagnostics,"Compiler source is outside the current inventory"))
        else
            basename(file)==file && !occursin('\\',file) || throw(ShenScopeError(:diagnostics,"External compiler source must be a basename"))
        end
    else
        throw(ShenScopeError(:diagnostics,"Unknown compiler source scope"))
    end
end

function compiler_ir_validate_method(value,target,snapshot,limits)
    fields=["identity","statements","slots","control_flow","slot_flow","ssa_flow","calls","return_type",
        "findings","inference_world","statistics","compiler_inferred","runtime_execution_observed"]
    compiler_ir_fields(value,fields,"method graph")
    expected=compiler_ir_method_identity(which(target.callable,target.arguments),snapshot)
    identity=value["identity"]
    compiler_ir_fields(identity,keys(expected),"method identity")
    for key in ("module","signature","file","line","source_sha256","argument_slots")
        identity[key]==expected[key] || throw(ShenScopeError(:diagnostics,"Compiler method identity does not match the trusted target"))
    end
    compiler_ir_integer(identity["line"],"method line",1,10_000_000)
    compiler_ir_integer(identity["argument_slots"],"method argument slots",0,limits.max_statements)
    for key in ("method_world_start","method_world_end")
        text=compiler_ir_text(identity[key],"method world",32)
        tryparse(UInt64,text)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid method world counter"))
    end
    rows=value["statements"];slots=value["slots"]
    rows isa AbstractVector && 1<=length(rows)<=limits.max_statements &&
        slots isa AbstractVector && length(slots)<=limits.max_statements || throw(ShenScopeError(:diagnostics,"Invalid compiler method dimensions"))
    for (id,slot) in enumerate(slots)
        compiler_ir_fields(slot,["id","name","inferred_type"],"slot")
        compiler_ir_integer(slot["id"],"slot id",id,id)
        slot["name"] isa String && isvalid(slot["name"]) && ncodeunits(slot["name"])<=256 && !occursin('\0',slot["name"]) ||
            throw(ShenScopeError(:diagnostics,"Invalid compiler slot name"))
        compiler_ir_validate_type(slot["inferred_type"])
    end
    operand_work=CompilerIRWork(limits)
    for (id,row) in enumerate(rows)
        compiler_ir_fields(row,["id","opcode","kind","inferred_type","produces_value","uses_ssa",
            "reads_slots","writes_slots","reset_slots","calls","source","operand","control"],"statement")
        compiler_ir_integer(row["id"],"statement id",id,id)
        compiler_ir_text(row["opcode"],"statement opcode",256)
        compiler_ir_text(row["kind"],"statement type",512)
        row["produces_value"] isa Bool || throw(ShenScopeError(:diagnostics,"Invalid compiler value-production flag"))
        compiler_ir_validate_type(row["inferred_type"])
        compiler_ir_indices(row["uses_ssa"],"SSA references",length(rows))
        for key in ("reads_slots","writes_slots","reset_slots")
            compiler_ir_indices(row[key],key,length(slots))
        end
        compiler_ir_validate_location(row["source"],snapshot)
        control=row["control"]
        control isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler control must be an object"))
        kind=get(control,"kind",nothing)
        kind in ("jump","branch","return","handler","fallthrough") || throw(ShenScopeError(:diagnostics,"Unknown compiler control operation"))
        compiler_ir_fields(control,kind=="handler" ? ["kind","destinations","exception_destination"] : ["kind","destinations"],"control operation")
        destinations=compiler_ir_indices(control["destinations"],"control destinations",length(rows))
        kind=="jump" && length(destinations)!=1 && throw(ShenScopeError(:diagnostics,"Compiler jump must have one destination"))
        kind=="branch" && !(1<=length(destinations)<=2) && throw(ShenScopeError(:diagnostics,"Invalid compiler branch destinations"))
        kind=="return" && !isempty(destinations) && throw(ShenScopeError(:diagnostics,"Compiler return has successors"))
        kind in ("fallthrough","handler") && destinations!=(id<length(rows) ? [id+1] : Int[]) &&
            throw(ShenScopeError(:diagnostics,"Compiler fallthrough destination disagrees"))
        kind=="handler" && compiler_ir_integer(control["exception_destination"],"exception destination",0,length(rows))
        row["calls"] isa AbstractVector && length(row["calls"])<=256 || throw(ShenScopeError(:diagnostics,"Invalid compiler statement calls"))
        for call in row["calls"]
            call isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler call must be an object"))
            compiler_ir_validate_call(call,length(rows),length(slots))
        end
        ssa=Int[];reads=Int[]
        compiler_ir_validate_operand(row["operand"],operand_work,ssa,reads;total=length(rows),slot_count=length(slots))
        sort!(unique(ssa))==row["uses_ssa"] && sort!(unique(reads))==row["reads_slots"] ||
            throw(ShenScopeError(:diagnostics,"Compiler operand reference projection disagrees"))
        operand=row["operand"]
        writes=operand["kind"]=="expression" && operand["head"]=="=" && !isempty(operand["arguments"]) &&
            first(operand["arguments"])["kind"]=="slot" ? [first(operand["arguments"])["id"]] : Int[]
        resets=operand["kind"]=="reset_slot" ? [operand["slot"]] : Int[]
        writes==row["writes_slots"] && resets==row["reset_slots"] ||
            throw(ShenScopeError(:diagnostics,"Compiler local definition projection disagrees"))
        expected_control=if operand["kind"]=="jump"
            Dict("kind"=>"jump","destinations"=>[operand["destination"]])
        elseif operand["kind"]=="conditional_branch"
            Dict("kind"=>"branch","destinations"=>sort!(unique(vcat([operand["destination"]],id<length(rows) ? [id+1] : Int[]))))
        elseif operand["kind"]=="return"
            Dict("kind"=>"return","destinations"=>Int[])
        elseif operand["kind"]=="exception_handler"
            Dict("kind"=>"handler","destinations"=>id<length(rows) ? [id+1] : Int[],"exception_destination"=>operand["destination"])
        else
            Dict("kind"=>"fallthrough","destinations"=>id<length(rows) ? [id+1] : Int[])
        end
        canonical(expected_control)==canonical(control) || throw(ShenScopeError(:diagnostics,"Compiler control operand projection disagrees"))
    end
    work=CompilerIRWork(limits)
    graph=compiler_ir_control_analysis(rows,work)
    canonical(graph)==canonical(value["control_flow"]) || throw(ShenScopeError(:diagnostics,"Compiler control-flow derivation disagrees"))
    flow=compiler_ir_slot_flow(rows,graph,slots,identity["argument_slots"],work)
    canonical(flow)==canonical(value["slot_flow"]) || throw(ShenScopeError(:diagnostics,"Compiler slot-flow derivation disagrees"))
    ssa=compiler_ir_ssa_flow(rows,work)
    canonical(ssa)==canonical(value["ssa_flow"]) || throw(ShenScopeError(:diagnostics,"Compiler SSA-flow derivation disagrees"))
    compiler_ir_validate_type(value["return_type"])
    value["compiler_inferred"]===true && value["runtime_execution_observed"]===false ||
        throw(ShenScopeError(:diagnostics,"Compiler report overstates runtime evidence"))
    calls=Dict{String,Any}[]
    for row in rows, (ordinal,call) in enumerate(row["calls"])
        push!(calls,merge(call,Dict("id"=>"call:"*string(row["id"])*":"*string(ordinal),"statement"=>row["id"],"source"=>row["source"])))
    end
    canonical(calls)==canonical(value["calls"]) || throw(ShenScopeError(:diagnostics,"Compiler call projection disagrees"))
    expected_findings=compiler_ir_findings(rows,slots,graph,flow,work)
    canonical(expected_findings)==canonical(value["findings"]) || throw(ShenScopeError(:diagnostics,"Compiler findings disagree"))
    statistics=value["statistics"]
    expected_stats=Dict("statements"=>length(rows),"slots"=>length(slots),"blocks"=>length(graph["blocks"]),
        "normal_edges"=>sum(length(row["successors"]) for row in graph["blocks"]),
        "ssa_edges"=>length(ssa["edges"]),"slot_reads"=>length(flow["reads"]),"calls"=>length(calls))
    compiler_ir_fields(statistics,vcat(collect(keys(expected_stats)),["operand_nodes","flow_operations"]),"statistics")
    for (key,expected_value) in expected_stats
        compiler_ir_integer(statistics[key],key,expected_value,expected_value)
    end
    compiler_ir_integer(statistics["operand_nodes"],"operand work",1,limits.max_operands)
    compiler_ir_integer(statistics["flow_operations"],"flow work",1,limits.max_flow_operations)
    compiler_ir_fields(value["inference_world"],["minimum","maximum"],"inference world")
    for text in values(value["inference_world"])
        compiler_ir_text(text,"inference world",32)
        tryparse(UInt64,text)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid compiler inference world"))
    end
end

function compiler_ir_validate_report(value,target::CompilerTarget,snapshot::RuntimeSourceSnapshot;
        limits=CompilerIRLimits())
    bounded_canonical_json(value;maximum=COMPILER_IR_MAX_BYTES)
    compiler_ir_fields(value,["schema","target","arguments","runtime","source","methods","methods_observed",
        "methods_truncated","effects","elapsed_seconds","limits","scope","report_sha256"],"report")
    value["schema"]==COMPILER_IR_SCHEMA && value["target"]==target.name && value["arguments"]==string(target.arguments) ||
        throw(ShenScopeError(:diagnostics,"Compiler report target or schema does not match"))
    compiler_ir_fields(value["source"],["fingerprint","uuid","version"],"source inventory")
    value["source"]==Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)) ||
        throw(ShenScopeError(:conflict,"Compiler report source inventory is stale"))
    compiler_ir_fields(value["runtime"],["julia_version","machine","observed_world"],"runtime")
    value["runtime"]["julia_version"]==string(Base.VERSION) && value["runtime"]["machine"]==string(Sys.MACHINE) ||
        throw(ShenScopeError(:diagnostics,"Compiler report platform does not match"))
    world=compiler_ir_text(value["runtime"]["observed_world"],"observed world",32)
    tryparse(UInt64,world)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid compiler observed world"))
    expected_limits=Dict(string(field)=>getfield(limits,field) for field in fieldnames(CompilerIRLimits))
    value["limits"]==expected_limits || throw(ShenScopeError(:diagnostics,"Compiler report limits changed"))
    total=compiler_ir_integer(value["methods_observed"],"method count",0,100_000)
    methods=value["methods"]
    methods isa AbstractVector && length(methods)==min(total,8) && value["methods_truncated"]== (total>8) &&
        value["methods_truncated"] isa Bool || throw(ShenScopeError(:diagnostics,"Compiler method collection is incomplete"))
    value["elapsed_seconds"] isa Real && !(value["elapsed_seconds"] isa Bool) && isfinite(value["elapsed_seconds"]) &&
        0<=value["elapsed_seconds"]<=3600 || throw(ShenScopeError(:diagnostics,"Invalid compiler elapsed time"))
    compiler_ir_text(value["scope"],"report scope",1024)
    value["scope"]=="fixed trusted Core methods; unoptimized compiler IR; no project loading or target execution" ||
        throw(ShenScopeError(:diagnostics,"Compiler report scope changed"))
    checksum=compiler_ir_text(value["report_sha256"],"report checksum",64)
    occursin(r"^[0-9a-f]{64}$",checksum) || throw(ShenScopeError(:diagnostics,"Invalid compiler report hash"))
    original=Dict(key=>item for (key,item) in value if key!="report_sha256")
    digest(canonical(original))==checksum || throw(ShenScopeError(:conflict,"Compiler report hash changed"))
    effects=value["effects"]
    effects isa AbstractDict && get(effects,"experimental",nothing)===true && get(effects,"safety_boundary",nothing)===false &&
        get(effects,"runtime_side_effects_observed",nothing)===false && get(effects,"julia_version",nothing)==string(Base.VERSION) &&
        get(effects,"available",nothing) isa Bool || throw(ShenScopeError(:diagnostics,"Invalid compiler effect evidence"))
    effect_common=["experimental","safety_boundary","runtime_side_effects_observed","julia_version","available"]
    if effects["available"]
        compiler_ir_fields(effects,vcat(effect_common,["proven_properties","version_specific_encoding","interpretation"]),"effects")
        properties=["consistent","effect_free","nothrow","terminates","notaskstate","inaccessiblememonly","noub","nonoverlayed","nortcall"]
        compiler_ir_fields(effects["proven_properties"],properties,"effect predicates")
        for item in values(effects["proven_properties"])
            item===nothing || item isa Bool || throw(ShenScopeError(:diagnostics,"Invalid compiler effect predicate"))
        end
        encoded=effects["version_specific_encoding"]
        encoded isa AbstractDict && all(key->key in properties,keys(encoded)) || throw(ShenScopeError(:diagnostics,"Unknown encoded compiler effect"))
        for item in values(encoded)
            item===nothing || item isa Bool || (item isa Integer && 0<=item<=255) ||
                throw(ShenScopeError(:diagnostics,"Invalid encoded compiler effect"))
        end
        compiler_ir_text(effects["interpretation"],"effect interpretation",1024)
    else
        compiler_ir_fields(effects,vcat(effect_common,["reason"]),"unavailable effects")
        compiler_ir_text(effects["reason"],"effect availability reason",1024)
    end
    for method in methods
        compiler_ir_validate_method(method,target,snapshot,limits)
    end
    value
end
