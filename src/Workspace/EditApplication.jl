function workspace_edit_receipt(plan::WorkspaceEditPlan, outcome::String, files;
        error_code=nothing, rollback_conflicts=String[])
    body = Dict{String,Any}("schema" => "shenscope.workspace-edit-receipt/1",
        "plan_id" => plan.id, "plan_sha256" => plan.sha256, "session_id" => plan.scope[3],
        "root_sha256" => digest(plan.scope[1]), "outcome" => outcome,
        "files" => files, "error_code" => error_code, "rollback_conflicts" => rollback_conflicts,
        "finished_at" => utcstamp(), "multi_file_power_loss_atomic" => false,
        "automatic_replay" => false, "core_file_locks_used" => true,
        "external_processes_can_change_files" => true)
    body["sha256"] = digest(bounded_canonical_json(body; maximum=128*1024, max_depth=12, max_nodes=16_000))
    body
end

function workspace_rollback!(applied::Vector{WorkspaceFileEdit}, ctx::RuntimeContext)
    conflicts = String[]
    restored = String[]
    for file in reverse(applied)
        try
            # Cancellation must not abandon ordinary rollback. Permissions
            # still apply, and an external change must never be overwritten.
            workspace_edit_permission(ctx, file; approve=false)
            permission_decision(ctx.permissions, PermissionRequest("workspace-rollback-read", :read,
                "workspace.apply", file.source.absolute, "Check rollback source")) != Deny ||
                throw(ShenScopeError(:permission, "Rollback source access is denied"))
            absolute, _ = workspace_snapshot_path(ctx, file.source.path)
            before = stat(absolute)
            before.size <= 8*1024^2 || throw(ShenScopeError(:conflict, "Rollback source grew beyond capacity"))
            current = open(input -> String(read(input, 8*1024^2+1)), absolute)
            workspace_source_identity(before) == workspace_source_identity(stat(absolute)) &&
                digest(current) == file.after_sha256 ||
                throw(ShenScopeError(:conflict, "Rollback would overwrite an external modification"))
            atomic_stream_write(absolute; maximum_bytes=8*1024^2, mode=file.mode,
                before_publish=(bytes,result)->begin
                    workspace_edit_permission(ctx, file; approve=false)
                    digest(read(absolute, String)) == file.after_sha256 ||
                        throw(ShenScopeError(:conflict, "Rollback source changed before replacement"))
                    true
                end) do output
                write(output, file.source.source.source)
            end
            push!(restored, file.source.path)
        catch
            push!(conflicts, file.source.path)
        end
    end
    restored, conflicts
end

function apply_workspace_edits!(manager::WorkspaceEditManager, id::AbstractString, ctx::RuntimeContext;
        expected_plan_sha256, before_file=(index,file)->nothing)
    plan = owned_workspace_edit_plan(manager, id, ctx)
    workspace_plan_expected_hash(plan, expected_plan_sha256)
    authorize!(ctx, :read, "workspace.apply", ctx.root; reason="Verify the reviewed workspace change proposal")
    workspace_plan_transition!(manager, plan, :prepared, :applying)
    applied = WorkspaceFileEdit[]
    receipt = nothing
    try
        receipt = with_workspace_file_locks(plan.files, ctx) do
            # Approve every destination and validate every original before the
            # first write. Locks are shared with the ordinary edit/write tools.
            for file in plan.files
                workspace_edit_permission(ctx, file)
                verify_workspace_snapshot(file.source, ctx; tool="workspace.apply")
            end
            try
                for (index, file) in enumerate(plan.files)
                    workspace_source_checkpoint(ctx)
                    before_file(index, file)
                    workspace_edit_permission(ctx, file; approve=false)
                    verify_workspace_snapshot(file.source, ctx; tool="workspace.apply")
                    file.source.sha256 == file.after_sha256 && continue
                    atomic_stream_write(file.source.absolute; maximum_bytes=manager.limits.maximum_file_bytes,
                        mode=file.mode, before_publish=(bytes,result)->begin
                            workspace_source_checkpoint(ctx)
                            workspace_edit_permission(ctx, file; approve=false)
                            verify_workspace_snapshot(file.source, ctx; tool="workspace.apply")
                            true
                        end) do output
                        write(output, file.after_text)
                    end
                    push!(applied, file)
                end
                rows = [Dict("path" => file.source.path, "before_sha256" => file.source.sha256,
                    "after_sha256" => file.after_sha256, "changed" => file.source.sha256 != file.after_sha256)
                    for file in plan.files]
                workspace_edit_receipt(plan, "applied", rows)
            catch cause
                restored, conflicts = workspace_rollback!(applied, ctx)
                outcome = isempty(applied) ? "not_applied" : isempty(conflicts) ? "rolled_back" : "partial"
                rows = [Dict("path" => file.source.path, "before_sha256" => file.source.sha256,
                    "after_sha256" => file.after_sha256, "restored" => file.source.path in restored,
                    "rollback_conflict" => file.source.path in conflicts) for file in applied]
                workspace_edit_receipt(plan, outcome, rows;
                    error_code=cause isa ShenScopeError ? String(cause.code) : "io_failure", rollback_conflicts=conflicts)
            end
        end
    catch cause
        receipt = workspace_edit_receipt(plan, "not_applied", Any[];
            error_code=cause isa ShenScopeError ? String(cause.code) : "io_failure")
    end
    lock(plan.mutex) do
        plan.receipt = deepcopy(receipt)
        plan.status = Symbol(receipt["outcome"])
    end
    # Preserve the receipt before notification. An unavailable UI does not
    # undo writes or permit this proposal to be silently replayed.
    try
        emit!(ctx, :workspace_edits_finished, Dict("plan_id" => plan.id,
            "plan_sha256" => plan.sha256, "receipt" => deepcopy(receipt)))
    catch
        nothing
    end
    receipt
end
