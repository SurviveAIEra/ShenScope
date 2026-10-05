function run_project_validation!(manager::ProjectValidationManager, ctx::RuntimeContext;
        argv, paths, cwd=".", family="generic", column_unit="unknown", label="Explicit project check", timeout=120.0)
    selected_family = validation_family(family)
    encoding = validation_column_unit(column_unit)
    title = workspace_edit_text(label, "validation command label", 512)
    directory, _ = workspace_snapshot_path(ctx, cwd; must_exist=false)
    isdir(directory) || throw(ShenScopeError(:validation, "Validation command directory does not exist"))
    authorize!(ctx, :read, "validation", ctx.root; reason="Run and interpret an explicitly selected project check")
    sources = capture_validation_sources(ctx, paths, manager.limits)
    created = utcstamp()
    execution = run_project_test_command!(manager.testing, ctx; argv, cwd, framework="raw", label=title,
        timeout, output_limit=64*1024)
    stdout_frames, stdout_summary = parse_validation_output(execution["process"]["stdout"], selected_family, "stdout", manager.limits)
    stderr_frames, stderr_summary = parse_validation_output(execution["process"]["stderr"], selected_family, "stderr", manager.limits)
    frames = vcat(stdout_frames, stderr_frames)
    frame_count = length(frames)
    frames = collect(Iterators.take(frames, manager.limits.maximum_diagnostics))
    files, interpretation = validation_problem_files(frames, sources, ctx, directory, selected_family, encoding, manager.limits)
    states = validation_source_states(sources, ctx)
    snapshot = retain_problem_snapshot!(manager.problems, ctx, "validation:" * selected_family, 0, files;
        coverage=Dict("producer_kind" => "explicit_command_output", "family" => selected_family,
            "selected_sources" => length(sources), "reported_diagnostics" => length(frames),
            "output_interpretation_complete" => false, "whole_project_checked" => false,
            "stdout" => stdout_summary, "stderr" => stderr_summary, "interpretation" => interpretation))
    process = execution["process"]
    report = Dict{String,Any}("schema" => PROJECT_VALIDATION_SCHEMA, "validation_id" => string(uuid4()),
        "session_id" => ctx.session_id, "root_sha256" => digest(ctx.root), "label" => title,
        "created_at" => created, "finished_at" => utcstamp(), "family" => selected_family,
        "column_unit" => encoding, "source_versions" => states,
        "execution_run_id" => execution["run_id"], "execution_receipt_sha256" => execution["sha256"],
        "problem_snapshot_id" => snapshot.id, "problem_snapshot_sha256" => snapshot.sha256,
        "exit_code" => process["exit_code"], "timed_out" => process["timed_out"],
        "cancelled" => execution["cancelled"], "permission_revoked" => process["permission_revoked"],
        "outcome" => execution["outcome"], "stdout" => process["stdout"], "stderr" => process["stderr"],
        "stdout_truncated" => execution["process"]["stdout_truncated"],
        "stderr_truncated" => execution["process"]["stderr_truncated"],
        "diagnostics_omitted_by_aggregate_limit" => frame_count-length(frames),
        "selected_source_versions_unchanged" => all(row -> row["source_version_unchanged"], states),
        "diagnostics_are_untrusted_output_interpretations" => true, "complete_project_coverage" => false,
        "all_project_inputs_snapshotted" => false, "automatic_replay" => false)
    report["sha256"] = digest(bounded_canonical_json(report; maximum=manager.limits.maximum_report_bytes-128, max_depth=32, max_nodes=100_000))
    retain_validation_report!(manager, report, ctx)
    report
end
