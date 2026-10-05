function with_workspace_file_locks(work::Function, files::Vector{WorkspaceFileEdit}, ctx::RuntimeContext)
    paths = sort!(unique(file.source.absolute for file in files))
    function acquire(index)
        index > length(paths) && return work()
        workspace_source_checkpoint(ctx)
        store_lock(joinpath(ctx.state_dir, "file-locks", digest(paths[index]))) do
            acquire(index + 1)
        end
    end
    acquire(1)
end

function workspace_plan_transition!(manager::WorkspaceEditManager, plan::WorkspaceEditPlan,
        expected::Symbol, next::Symbol)
    lock(manager.mutex) do
        get(manager.plans, plan.id, nothing) === plan ||
            throw(ShenScopeError(:workspace_edit, "Workspace edit plan was retired before use"))
        lock(plan.mutex) do
            plan.status == expected || throw(ShenScopeError(:conflict, "Workspace edit plan is not in the required state"))
            plan.status = next
        end
    end
    nothing
end

function workspace_edit_permission(ctx::RuntimeContext, file::WorkspaceFileEdit; approve=true)
    absolute, _ = workspace_snapshot_path(ctx, file.source.path)
    absolute == file.source.absolute || throw(ShenScopeError(:conflict, "Workspace edit path changed after preview"))
    UInt(filemode(absolute) & 0o777) == file.mode ||
        throw(ShenScopeError(:conflict, "Workspace file permissions changed after preview"))
    request = PermissionRequest("workspace-edit-recheck", :edit, "workspace.apply", absolute,
        "Apply reviewed, source-hash-guarded workspace changes")
    permission_decision(ctx.permissions, request) != Deny ||
        throw(ShenScopeError(:permission, "Workspace edit permission was revoked"))
    approve && authorize!(ctx, :edit, "workspace.apply", absolute; reason=request.reason)
    nothing
end

function workspace_plan_expected_hash(plan::WorkspaceEditPlan, expected)
    workspace_edit_hash(expected, "expected workspace proposal hash") == plan.sha256 ||
        throw(ShenScopeError(:conflict, "Workspace proposal hash differs from the reviewed plan"))
    nothing
end

function workspace_after_snapshot(file::WorkspaceFileEdit, ctx::RuntimeContext)
    read_workspace_snapshot(ctx, file.source.path; expected_sha256=file.after_sha256,
        tool="workspace.verify", unicode_line_separators=file.source.source.unicode_line_separators)
end
