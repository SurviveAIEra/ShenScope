function verify_workspace_check!(manager::WorkspaceEditManager, validation::ProjectValidationManager,
        id::AbstractString, ctx::RuntimeContext; expected_plan_sha256, argv, cwd=".", family="generic",
        column_unit="unknown", label="Check reviewed workspace changes", timeout=120.0)
    with_workspace_verification!(manager, id, ctx; expected_plan_sha256, kind="project_check") do plan
        report = run_project_validation!(validation, ctx; argv, cwd, family, column_unit, label, timeout,
            paths=[file.source.path for file in plan.files])
        Dict("validation_id" => report["validation_id"], "validation_sha256" => report["sha256"],
            "problem_snapshot_id" => report["problem_snapshot_id"],
            "problem_snapshot_sha256" => report["problem_snapshot_sha256"],
            "execution_run_id" => report["execution_run_id"], "execution_receipt_sha256" => report["execution_receipt_sha256"],
            "outcome" => report["outcome"], "exit_code" => report["exit_code"],
            "selected_source_versions_unchanged" => report["selected_source_versions_unchanged"])
    end
end
