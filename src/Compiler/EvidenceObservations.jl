function runtime_evidence_validate_reports(compiler,profile,snapshot::RuntimeSourceSnapshot)
    compiler!==nothing || profile!==nothing || throw(ShenScopeError(:diagnostics,"Select a compiler or runtime measurement report"))
    reports=filter(!isnothing,[compiler,profile])
    first_report=first(reports);target=compiler_target(first_report["target"])
    all(report->report["target"]==target.name && report["arguments"]==string(target.arguments),reports) ||
        throw(ShenScopeError(:diagnostics,"Runtime evidence reports require the same target and concrete signature"))
    compiler===nothing || compiler_ir_validate_report(compiler,target,snapshot;limits=compiler_archive_limits(compiler))
    profile===nothing || compiler_profile_validate_report(profile,target,snapshot;
        limits=compiler_profile_limits_from_view(profile["limits"]),fixture=profile["fixture"]["name"])
    target.name
end

function runtime_evidence_position(snapshot::RuntimeSourceSnapshot,file,line;scope="core")
    if scope!="core" || file===nothing || line===nothing || line<=0
        return Dict("file"=>nothing,"line"=>nothing,"source_sha256"=>nothing,"scope"=>String(scope))
    end
    index=findfirst(source->source.path==file,snapshot.files)
    index!==nothing && startswith(file,"src/") && endswith(file,".jl") ||
        throw(ShenScopeError(:diagnostics,"Runtime observation source is outside the recorded authored Julia inventory"))
    Dict("file"=>String(file),"line"=>compiler_ir_integer(line,"evidence source line",1,10_000_000),
        "source_sha256"=>snapshot.files[index].sha256,"scope"=>"core")
end

function runtime_evidence_push!(rows,kind,handle,source,details,report_sha256,limits)
    length(rows)<limits.observations || throw(ShenScopeError(:capacity,"Runtime observation count exceeds capacity"))
    key=digest(canonical(["runtime-observation",kind,report_sha256,handle]))
    push!(rows,Dict("key"=>key,"kind"=>kind,"handle"=>handle,"source"=>source,"details"=>details,
        "report_sha256"=>report_sha256))
end

function runtime_evidence_observations(compiler,profile,snapshot::RuntimeSourceSnapshot,work::RuntimeEvidenceWork)
    rows=Dict{String,Any}[]
    if compiler!==nothing
        for (method_index,method) in enumerate(compiler["methods"])
            identity=method["identity"];sha=compiler["report_sha256"]
            runtime_evidence_push!(rows,"method",Dict("method_index"=>method_index),
                runtime_evidence_position(snapshot,identity["file"],identity["line"]),
                Dict("signature"=>identity["signature"],"module"=>identity["module"],
                    "compiler_inferred"=>true,"runtime_execution_observed"=>false),sha,work.limits)
            for row in method["statements"]
                runtime_evidence_tick!(work)
                position=row["source"]
                runtime_evidence_push!(rows,"statement",Dict("method_index"=>method_index,"statement_id"=>row["id"]),
                    runtime_evidence_position(snapshot,position["file"],position["line"];scope=position["scope"]),
                    Dict("opcode"=>row["opcode"],"inferred_type"=>deepcopy(row["inferred_type"]),
                        "produces_value"=>row["produces_value"],"calls"=>deepcopy(row["calls"]),
                        "compiler_inferred"=>true,"runtime_execution_observed"=>false),sha,work.limits)
            end
        end
    end
    if profile!==nothing
        for sample in profile["samples"]
            frames=sample["core_frames"]
            for frame_index in 1:max(1,length(frames))
                runtime_evidence_tick!(work)
                frame=isempty(frames) ? nothing : frames[frame_index]
                position=frame===nothing ? runtime_evidence_position(snapshot,nothing,nothing;scope="unattributed") :
                    runtime_evidence_position(snapshot,frame["file"],frame["line"])
                details=Dict("sample_id"=>sample["id"],"sampled_type"=>sample["type"],"sampled_bytes"=>sample["bytes"],
                    "frame"=>frame===nothing ? nothing : deepcopy(frame),
                    "frame_lists_truncated"=>sample["core_frames_truncated"],"stack_scan_truncated"=>sample["stack_scan_truncated"],
                    "sampled_allocation_observed"=>true,"selected_target_binding_confirmed"=>false,
                    "attribution_scope"=>"retained allocation frame; helper background activity may contribute")
                runtime_evidence_push!(rows,"allocation",Dict("sample_id"=>sample["id"],"frame_index"=>frame===nothing ? 0 : frame_index),
                    position,details,profile["report_sha256"],work.limits)
            end
        end
    end
    sort!(rows;by=row->(something(row["source"]["file"],"~"),something(row["source"]["line"],typemax(Int)),row["kind"],row["key"]))
    rows
end

function runtime_evidence_report_stamp(report,kind)
    Dict("kind"=>kind,"report_sha256"=>report["report_sha256"],"target"=>report["target"],
        "arguments"=>report["arguments"],"runtime"=>deepcopy(report["runtime"]),"source"=>deepcopy(report["source"]))
end
