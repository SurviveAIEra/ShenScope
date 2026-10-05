function runtime_evidence_join_row(row::AbstractDict,candidates::AbstractVector{RuntimeEvidenceDeclaration})
    source=row["source"];count=length(candidates)
    status=source["file"]===nothing ? "no_source_position" : count==0 ? "no_declaration" :
        count>1 ? "ambiguous_declarations" : row["kind"]=="method" &&
            only(candidates).symbol.location.start_line==source["line"] ? "unique_declaration_start" : "unique_containing_declaration"
    witnesses=Dict{String,Any}[]
    for candidate in candidates
        key=digest(canonical(["source-declaration-witness",row["key"],candidate.key,source["source_sha256"]]))
        push!(witnesses,Dict("key"=>key,"declaration"=>runtime_evidence_declaration_view(candidate),
            "source_sha256"=>source["source_sha256"],"observed_line"=>source["line"],
            "relation"=>"same_source_hash_and_containing_line_range","runtime_binding_confirmed"=>false))
    end
    merge(row,Dict("join_status"=>status,"declaration_candidates"=>witnesses,"candidate_count"=>count,
        "semantic_equivalence_confirmed"=>false))
end

function runtime_evidence_summary(rows,declarations,paths,work::RuntimeEvidenceWork)
    statuses=Dict(status=>count(row->row["join_status"]==status,rows) for status in
        ("no_source_position","no_declaration","ambiguous_declarations","unique_declaration_start","unique_containing_declaration"))
    kinds=Dict(kind=>count(row->row["kind"]==kind,rows) for kind in RUNTIME_EVIDENCE_KINDS if kind!="all")
    Dict("observations"=>length(rows),"observation_kinds"=>kinds,"join_statuses"=>statuses,
        "selected_files"=>length(paths),"callable_declarations"=>length(declarations),
        "join_work_operations"=>work.operations,"line_only_matching"=>true,"columns_used_for_binding"=>false,
        "allocation_observation_bytes_are_additive"=>false,"sampling_frame_occurrences_are_additive"=>false,
        "automatic_project_indexing"=>false)
end

function runtime_evidence_build(compiler,profile,snapshot::RuntimeSourceSnapshot,ctx::RuntimeContext;
        limits=RuntimeEvidenceLimits(),sampling=nothing,authorized=false)
    root=runtime_core_root()
    snapshot.root==root || throw(ShenScopeError(:permission,"Runtime evidence accepts only the installed Core inventory"))
    authorized || authorize!(ctx,:read,"runtime.diagnostics",root;
        reason="Associate owned inference and measured allocation positions with hash-verified Core declarations")
    compiler_source_checkpoint(ctx,root)
    target=runtime_evidence_validate_reports(compiler,profile,snapshot;sampling)
    work=RuntimeEvidenceWork(limits,0,ctx)
    observations=runtime_evidence_observations(compiler,profile,snapshot,work;sampling)
    facts=runtime_evidence_read_facts(observations,snapshot,ctx,limits)
    declarations=runtime_evidence_declarations(facts,snapshot,"julia_syntax",work)
    indexes=runtime_evidence_intervals(declarations)
    rows=[runtime_evidence_join_row(row,runtime_evidence_candidates(row,indexes,work)) for row in observations]
    report_stamps=Dict{String,Any}[]
    compiler===nothing || push!(report_stamps,runtime_evidence_report_stamp(compiler,"compiler"))
    profile===nothing || push!(report_stamps,runtime_evidence_report_stamp(profile,"profile"))
    sampling===nothing || push!(report_stamps,runtime_evidence_report_stamp(sampling,"sampling"))
    file_stamps=[Dict("file"=>file.path,"source_sha256"=>file.sha256,"facts_sha256"=>digest(canonical(facts_dict(file)))) for file in facts]
    provider_stamps=[Dict{String,Any}("provider"=>"julia_syntax","parser_version"=>string(Base.pkgversion(JuliaSyntax)),
        "files"=>file_stamps,"selection_sha256"=>digest(canonical(file_stamps)),"source_evaluated"=>false,
        "persistent_index_revision"=>nothing,"capabilities"=>capability_dict(backend_capabilities(JuliaSyntaxBackend())))]
    summary=runtime_evidence_summary(rows,declarations,file_stamps,work)
    profile_summary=profile===nothing ? nothing : Dict("allocation"=>deepcopy(profile["allocation_summary"]),
        "timing"=>deepcopy(profile["timing_summary"]),"fixture"=>deepcopy(profile["fixture"]),
        "notes"=>deepcopy(profile["measurement_notes"]))
    sampling_summary=sampling===nothing ? nothing : Dict("sampling"=>deepcopy(sampling["sampling_summary"]),
        "run"=>deepcopy(sampling["run"]),"buffer"=>deepcopy(sampling["buffer"]),"fixture"=>deepcopy(sampling["fixture"]),
        "notes"=>deepcopy(sampling["measurement_notes"]))
    body=Dict("schema"=>RUNTIME_EVIDENCE_SCHEMA,"source_fingerprint"=>snapshot.fingerprint,
        "target"=>target,"report_stamps"=>report_stamps,"provider_stamps"=>provider_stamps,"rows"=>rows,
        "summary"=>summary,"profile_summary"=>profile_summary,"sampling_summary"=>sampling_summary)
    bounded_canonical_json(body;maximum=limits.retained_bytes)
    fingerprint=digest(canonical(body))
    runtime_source_snapshot(ctx;root,authorized=true).fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Core source changed during runtime evidence association"))
    compiler_source_checkpoint(ctx,root)
    RuntimeEvidenceSnapshot(snapshot,target,report_stamps,provider_stamps,rows,declarations,summary,profile_summary,sampling_summary,fingerprint)
end
