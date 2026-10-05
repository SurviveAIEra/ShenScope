compiler_archive_method_key(method)=canonical(Dict(key=>method["identity"][key] for key in ("module","signature","file")))

function compiler_archive_group(rows,key::Function)
    groups=Dict{String,Vector{Any}}()
    for row in rows
        identity=key(row)
        identity===nothing && continue
        push!(get!(groups,identity,Any[]),row)
    end
    groups
end

function compiler_archive_statement_anchor(row)
    source=row["source"]
    # External records contain only basenames, which cannot identify a file.
    source["scope"]=="core" && source["line"]>0 || return nothing
    canonical(Dict("source"=>source,"opcode"=>row["opcode"],"kind"=>row["kind"]))
end

function compiler_archive_call_key(call)
    identity=Dict{String,Any}("kind"=>call["kind"],"operation"=>call["operation"])
    for key in ("module","name","signature","type")
        haskey(call,key) && (identity[key]=call[key])
    end
    canonical(identity)
end

function compiler_archive_call_counts(method)
    groups=compiler_archive_group(method["calls"],compiler_archive_call_key)
    Dict(key=>length(rows) for (key,rows) in groups)
end

function compiler_archive_uncertain_count(method)
    count(row->row["produces_value"] && row["inferred_type"]["classification"] in
        ("any","nonconcrete","compiler_lattice_value"),method["statements"])
end

function compiler_archive_method_comparison(before,after,retain::Function,ctx,store)
    signature=after["identity"]["signature"]
    statistics=Dict(key=>after["statistics"][key]-before["statistics"][key] for key in keys(before["statistics"]))
    before["return_type"]==after["return_type"] || retain(Dict("kind"=>"return_type_changed","method"=>signature,
        "before"=>before["return_type"],"after"=>after["return_type"]))
    any(!=(0),values(statistics)) && retain(Dict("kind"=>"compiler_statistics_changed","method"=>signature,"delta"=>statistics))
    left=compiler_archive_group(before["statements"],compiler_archive_statement_anchor)
    right=compiler_archive_group(after["statements"],compiler_archive_statement_anchor)
    shared=sort!(collect(intersect(Set(keys(left)),Set(keys(right)))))
    paired=0;ambiguous=0
    for key in shared
        compiler_archive_checkpoint(store,ctx,:read)
        if length(left[key])!=1 || length(right[key])!=1
            ambiguous+=1;continue
        end
        first=only(left[key]);second=only(right[key]);paired+=1
        if first["inferred_type"]!=second["inferred_type"] || first["produces_value"]!=second["produces_value"]
            retain(Dict("kind"=>"source_anchored_inferred_value_changed","method"=>signature,
                "source"=>second["source"],"opcode"=>second["opcode"],"statement_before"=>first["id"],
                "statement_after"=>second["id"],"before"=>first["inferred_type"],"after"=>second["inferred_type"],
                "produces_value_before"=>first["produces_value"],"produces_value_after"=>second["produces_value"]))
        end
    end
    old_calls=compiler_archive_call_counts(before);new_calls=compiler_archive_call_counts(after)
    for key in sort!(collect(union(Set(keys(old_calls)),Set(keys(new_calls)))))
        old=get(old_calls,key,0);new=get(new_calls,key,0)
        if old!=new
            retain(Dict("kind"=>"callee_class_count_changed","method"=>signature,"callee"=>parsejson(key),
                "before"=>old,"after"=>new,"runtime_dispatch_confirmed"=>false))
        end
    end
    Dict("signature"=>signature,"file"=>after["identity"]["file"],
        "source_changed"=>before["identity"]["source_sha256"]!=after["identity"]["source_sha256"],
        "return_type_before"=>before["return_type"],"return_type_after"=>after["return_type"],
        "statistics_delta"=>statistics,"uncertain_values_before"=>compiler_archive_uncertain_count(before),
        "uncertain_values_after"=>compiler_archive_uncertain_count(after),"uniquely_source_anchored_pairs"=>paired,
        "ambiguous_shared_anchors"=>ambiguous,"unpaired_statements_before"=>length(before["statements"])-paired,
        "unpaired_statements_after"=>length(after["statements"])-paired,
        "source_positions_before"=>compiler_source_positions(before),
        "source_positions_after"=>compiler_source_positions(after),
        "normal_cycle_groups_before"=>length(before["control_flow"]["loops"]["cycle_groups"]),
        "normal_cycle_groups_after"=>length(after["control_flow"]["loops"]["cycle_groups"]))
end

function compiler_archive_compare(store::CompilerArchiveStore,left_id::String,right_id::String,ctx::RuntimeContext;
        limit=128,expected_index_sha256=nothing)
    compiler_archive_hash(left_id);compiler_archive_hash(right_id)
    limit=compiler_ir_integer(limit,"comparison change limit",1,512)
    expected_index_sha256===nothing || compiler_archive_hash(expected_index_sha256,"expected catalog digest")
    compiler_archive_authorize(store,ctx,:read)
    index=compiler_archive_read_index(store,ctx)
    expected_index_sha256===nothing || expected_index_sha256==index["index_sha256"] ||
        throw(ShenScopeError(:conflict,"Compiler archive changed before comparison"))
    first=compiler_archive_asset(store,left_id,ctx;entry=compiler_archive_index_entry(index,left_id))
    second=compiler_archive_asset(store,right_id,ctx;entry=compiler_archive_index_entry(index,right_id))
    left=first.asset["report"];right=second.asset["report"]
    header=Dict{String,Any}("before"=>left_id,"after"=>right_id,"revision"=>index["revision"],
        "index_sha256"=>index["index_sha256"],"target_before"=>left["target"],"target_after"=>right["target"],
        "source_changed"=>left["source"]["fingerprint"]!=right["source"]["fingerprint"],
        "performance_change_proven"=>false,"behavior_equivalence_proven"=>false,"producer_authenticated"=>false,
        "statement_matching"=>"unique authored Core source location, opcode and operand kind; ambiguous anchors remain unpaired",
        "callee_matching"=>"compiler callee classes; local SSA and slot IDs are not runtime function identities")
    reasons=String[]
    left["target"]==right["target"] || push!(reasons,"target_changed")
    left["arguments"]==right["arguments"] || push!(reasons,"argument_signature_changed")
    left["runtime"]["julia_version"]==right["runtime"]["julia_version"] || push!(reasons,"julia_version_changed")
    left["runtime"]["machine"]==right["runtime"]["machine"] || push!(reasons,"compiler_platform_changed")
    if !isempty(reasons)
        compiler_archive_checkpoint(store,ctx,:read)
        return merge(header,Dict("comparable"=>false,"reasons"=>reasons,"changes"=>Any[],"methods"=>Any[]))
    end
    changes=Dict{String,Any}[];total=Ref(0)
    retain=entry->begin
        total[]+=1
        length(changes)<limit && push!(changes,entry)
        nothing
    end
    old=compiler_archive_group(left["methods"],compiler_archive_method_key)
    new=compiler_archive_group(right["methods"],compiler_archive_method_key)
    methods=Dict{String,Any}[];ambiguous_methods=0
    for key in sort!(collect(union(Set(keys(old)),Set(keys(new)))))
        compiler_archive_checkpoint(store,ctx,:read)
        if !haskey(old,key)
            retain(Dict("kind"=>"method_added","identity"=>new[key][1]["identity"]));continue
        elseif !haskey(new,key)
            retain(Dict("kind"=>"method_removed","identity"=>old[key][1]["identity"]));continue
        elseif length(old[key])!=1 || length(new[key])!=1
            ambiguous_methods+=1;continue
        end
        push!(methods,compiler_archive_method_comparison(only(old[key]),only(new[key]),retain,ctx,store))
    end
    left["effects"]["available"]==right["effects"]["available"] || retain(Dict("kind"=>"effect_availability_changed",
        "before"=>left["effects"]["available"],"after"=>right["effects"]["available"],"safety_boundary"=>false))
    if left["effects"]["available"] && right["effects"]["available"]
        for name in sort!(collect(keys(left["effects"]["proven_properties"])))
            before=left["effects"]["proven_properties"][name];after=right["effects"]["proven_properties"][name]
            before==after || retain(Dict("kind"=>"experimental_effect_predicate_changed","property"=>name,
                "before"=>before,"after"=>after,"safety_boundary"=>false))
        end
    end
    result=merge(header,Dict("comparable"=>true,"changes"=>changes,"changes_total"=>total[],"changes_truncated"=>total[]>limit,
        "methods"=>methods,"ambiguous_method_keys"=>ambiguous_methods,
        "reports_truncated"=>left["methods_truncated"] || right["methods_truncated"],
        "analysis"=>"bounded differences in recorded compiler observations; no target execution or runtime measurement"))
    compiler_archive_checkpoint(store,ctx,:read)
    bounded_canonical_json(result;maximum=1024*1024,max_depth=24,max_nodes=100_000)
    result
end
