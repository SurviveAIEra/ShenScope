function read_workspace_edit_plan(manager::WorkspaceEditManager, id::AbstractString, ctx::RuntimeContext)
    plan = owned_workspace_edit_plan(manager, id, ctx)
    authorize!(ctx, :read, "workspace.preview", ctx.root; reason="Read an owned workspace edit plan and its application receipt")
    for file in plan.files
        absolute, _ = workspace_snapshot_path(ctx, file.source.path; must_exist=false)
        workspace_source_permission(ctx, absolute, "workspace.preview")
    end
    workspace_edit_plan_view(plan)
end

function read_workspace_edit_source(manager::WorkspaceEditManager, id::AbstractString, path::AbstractString,
        ctx::RuntimeContext; side="after", maximum_bytes=128*1024)
    side in ("before", "after") || throw(ShenScopeError(:workspace_edit, "Edit source side must be before or after"))
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 128 <= maximum_bytes <= 512*1024 ||
        throw(ShenScopeError(:workspace_edit, "Invalid edit source preview capacity"))
    plan = owned_workspace_edit_plan(manager, id, ctx)
    absolute, relative = workspace_snapshot_path(ctx, path; must_exist=false)
    workspace_source_permission(ctx, absolute, "workspace.preview")
    match = findfirst(file -> file.source.path == relative, plan.files)
    match === nothing && throw(ShenScopeError(:workspace_edit, "File is not in this owned edit proposal"))
    file = plan.files[match]
    text = side == "before" ? file.source.source.source : file.after_text
    Dict("plan_id" => plan.id, "plan_sha256" => plan.sha256, "path" => relative,
        "side" => side, "source_sha256" => side == "before" ? file.source.sha256 : file.after_sha256,
        "text" => cliptext(text, maximum_bytes), "truncated" => ncodeunits(text) > maximum_bytes,
        "origin" => "retained_reviewed_proposal", "content_is_current_disk_source" => false)
end

function discard_workspace_edit_plan!(manager::WorkspaceEditManager, id::AbstractString, ctx::RuntimeContext;
        expected_plan_sha256)
    plan = owned_workspace_edit_plan(manager, id, ctx)
    workspace_plan_expected_hash(plan, expected_plan_sha256)
    authorize!(ctx, :read, "workspace.preview", ctx.root; reason="Discard an owned in-memory workspace edit proposal")
    lock(manager.mutex) do
        lock(plan.mutex) do
            plan.status in (:applying, :verifying) &&
                throw(ShenScopeError(:workspace_edit, "A running workspace proposal cannot be discarded"))
            get(manager.plans, plan.id, nothing) === plan ||
                throw(ShenScopeError(:workspace_edit, "Workspace proposal has already been retired"))
            delete!(manager.plans, plan.id)
            filter!(other -> other != plan.id, manager.order)
            manager.retained_bytes -= plan.bytes
        end
    end
    Dict("discarded" => true, "plan_id" => plan.id, "workspace_files_changed" => false)
end
