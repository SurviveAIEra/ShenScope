function capture_sarif_sources(ctx::RuntimeContext, values, limits::ValidationLimits)
    values isa AbstractVector && 1 <= length(values) <= limits.maximum_files ||
        throw(ShenScopeError(:sarif, "SARIF import requires a bounded source-version manifest"))
    sources = Dict{String,WorkspaceSourceSnapshot}()
    total = 0
    for value in values
        workspace_edit_fields(value, ["path", "expected_sha256"], String[], "SARIF source version")
        snapshot = read_workspace_snapshot(ctx, workspace_edit_text(value["path"], "SARIF source path", 4096);
            expected_sha256=workspace_edit_hash(value["expected_sha256"], "SARIF selected source hash"),
            maximum_bytes=limits.maximum_file_bytes, tool="validation.source", unicode_line_separators=false)
        haskey(sources, snapshot.path) && throw(ShenScopeError(:sarif, "SARIF source manifest repeats a file"))
        total += ncodeunits(snapshot.source.source)
        total <= limits.maximum_source_bytes || throw(ShenScopeError(:capacity, "SARIF source selection exceeds capacity"))
        sources[snapshot.path] = snapshot
    end
    sources
end

function import_sarif_report!(manager::ProjectValidationManager, ctx::RuntimeContext;
        path, expected_report_sha256, source_versions, label="Imported SARIF report", limits=SarifLimits())
    validate_sarif_limits(limits)
    authorize!(ctx, :read, "validation", ctx.root; reason="Import an explicitly selected static-analysis report")
    title = workspace_edit_text(label, "SARIF report label", 512)
    report = read_workspace_snapshot(ctx, path;
        expected_sha256=workspace_edit_hash(expected_report_sha256, "SARIF report hash"),
        maximum_bytes=limits.maximum_report_bytes, tool="validation.source", unicode_line_separators=false)
    document = bounded_json_object(report.source.source; maximum=limits.maximum_report_bytes,
        max_depth=32, max_nodes=200_000, max_string_bytes=limits.maximum_report_bytes, error_code=:sarif)
    sources = capture_sarif_sources(ctx, source_versions, manager.limits)
    files, coverage = parse_sarif_problems(document, sources, ctx; limits,
        maximum_diagnostics=manager.limits.maximum_diagnostics)
    for snapshot in values(sources)
        verify_workspace_snapshot(snapshot, ctx; tool="validation.source")
    end
    verify_workspace_snapshot(report, ctx; tool="validation.source")
    workspace_source_checkpoint(ctx)
    snapshot = retain_problem_snapshot!(manager.problems, ctx, "sarif", 0, files; coverage)
    result = Dict{String,Any}("schema" => PROJECT_VALIDATION_SCHEMA, "validation_id" => string(uuid4()),
        "session_id" => ctx.session_id, "root_sha256" => digest(ctx.root), "label" => title,
        "created_at" => utcstamp(), "finished_at" => utcstamp(), "family" => "sarif",
        "report_path" => report.path, "report_sha256" => report.sha256,
        "problem_snapshot_id" => snapshot.id, "problem_snapshot_sha256" => snapshot.sha256,
        "source_versions" => [Dict("path" => value.path, "source_sha256" => value.sha256)
            for value in sort!(collect(values(sources)); by=value -> value.path)],
        "outcome" => "report_imported", "coverage" => coverage, "commands_executed" => false,
        "all_project_inputs_snapshotted" => false, "complete_project_coverage" => false,
        "caller_manifest_matches_current_disk" => true, "producer_authenticated" => false,
        "historical_report_source_binding_is_caller_assertion" => true,
        "automatic_fix_execution" => false, "automatic_replay" => false)
    result["sha256"] = digest(bounded_canonical_json(result; maximum=manager.limits.maximum_report_bytes-128,
        max_depth=32, max_nodes=100_000))
    retain_validation_report!(manager, result, ctx)
    result
end
