function workspace_verification_sources(plan::WorkspaceEditPlan, ctx::RuntimeContext)
    rows = Dict{String,Any}[]
    for file in plan.files
        current = workspace_after_snapshot(file, ctx)
        push!(rows, Dict("path" => current.path, "source_sha256" => current.sha256))
    end
    rows
end

function verify_workspace_edits!(manager::WorkspaceEditManager, testing::ProjectTestManager,
        id::AbstractString, ctx::RuntimeContext; expected_plan_sha256, catalog_id, candidate_ids,
        timeout=120.0, stop_on_failure=false)
    plan = owned_workspace_edit_plan(manager, id, ctx)
    workspace_plan_expected_hash(plan, expected_plan_sha256)
    authorize!(ctx, :read, "workspace.verify", ctx.root; reason="Verify applied workspace changes using explicitly selected project test commands")
    workspace_plan_transition!(manager, plan, :applied, :verifying)
    result = nothing
    try
        before = workspace_verification_sources(plan, ctx)
        runs = run_project_test_set!(testing, ctx; catalog_id, candidate_ids, timeout, stop_on_failure)
        after = workspace_verification_sources(plan, ctx)
        before == after || throw(ShenScopeError(:conflict, "Edited source changed while verification commands ran"))
        result = Dict{String,Any}("schema" => "shenscope.workspace-verification/1",
            "plan_id" => plan.id, "plan_sha256" => plan.sha256,
            "application_receipt_sha256" => plan.receipt["sha256"], "source_versions" => after,
            "run_set_id" => runs["run_set_id"], "run_set_sha256" => runs["sha256"],
            "outcome" => runs["outcome"], "commands" => runs["commands"],
            "not_started_candidate_ids" => runs["not_started_candidate_ids"],
            "edited_source_versions_unchanged_during_commands" => true,
            "complete_project_coverage" => false, "all_project_inputs_snapshotted" => false,
            "automatic_replay" => false, "finished_at" => utcstamp())
        result["sha256"] = digest(bounded_canonical_json(result; maximum=4*1024^2, max_depth=24, max_nodes=100_000))
        lock(plan.mutex) do
            plan.verification = deepcopy(result)
            # Explicit verification can be run again. Applying the same edit
            # proposal remains forbidden, independent of the test outcome.
            plan.status = :applied
        end
    catch cause
        result = Dict{String,Any}("schema" => "shenscope.workspace-verification/1",
            "plan_id" => plan.id, "plan_sha256" => plan.sha256,
            "outcome" => "verification_unconfirmed", "error_code" => cause isa ShenScopeError ? String(cause.code) : "internal",
            "commands_may_have_run" => true, "automatic_replay" => false,
            "complete_project_coverage" => false, "finished_at" => utcstamp())
        result["sha256"] = digest(canonical(result))
        lock(plan.mutex) do
            plan.verification = deepcopy(result)
            plan.status = :applied
        end
    end
    result
end
