function workspace_plan_manifest(plan::WorkspaceEditPlan)
    Dict("schema" => WORKSPACE_EDIT_SCHEMA, "plan_id" => plan.id,
        "root_sha256" => digest(plan.scope[1]), "session_id" => plan.scope[3],
        "title" => plan.title, "origin" => plan.origin, "created_at" => plan.created_at,
        "files" => [Dict("path" => file.source.path, "before_sha256" => file.source.sha256,
            "after_sha256" => file.after_sha256, "before_bytes" => ncodeunits(file.source.source.source),
            "after_bytes" => ncodeunits(file.after_text), "edits" => [Dict("location" => range_dict(edit.location),
                "new_text_sha256" => digest(edit.new_text), "new_text_bytes" => ncodeunits(edit.new_text)) for edit in file.edits],
            "line_break_policy" => file.source.source.unicode_line_separators ? "unicode_source" : "lsp_cr_lf") for file in plan.files],
        "requires_explicit_apply" => true, "multi_file_power_loss_atomic" => false)
end

function prepare_workspace_edits!(manager::WorkspaceEditManager, ctx::RuntimeContext, files;
        title="Workspace changes", origin="explicit_proposal")
    limits = manager.limits
    files isa AbstractVector && 1 <= length(files) <= limits.maximum_files ||
        throw(ShenScopeError(:workspace_edit, "Workspace proposal requires a bounded nonempty file list"))
    description = workspace_edit_text(title, "workspace edit title", 1024)
    provenance = workspace_edit_text(origin, "workspace edit origin", 256)
    authorize!(ctx, :read, "workspace.preview", ctx.root; reason="Prepare a reviewable workspace change proposal")
    plans = WorkspaceFileEdit[]
    total = 0
    edit_count = 0
    replacements = 0
    paths = Set{String}()
    for row in files
        workspace_source_checkpoint(ctx)
        file = workspace_validate_file_edit(row, ctx, limits)
        file.source.path in paths && throw(ShenScopeError(:workspace_edit, "Workspace proposal repeats a file"))
        push!(paths, file.source.path)
        total += ncodeunits(file.source.source.source) + ncodeunits(file.after_text)
        edit_count += length(file.edits)
        replacements += sum(ncodeunits(edit.new_text) for edit in file.edits; init=0)
        total <= limits.maximum_total_bytes && edit_count <= limits.maximum_edits &&
            replacements <= limits.maximum_replacement_bytes ||
            throw(ShenScopeError(:capacity, "Workspace proposal exceeds aggregate source or edit capacity"))
        push!(plans, file)
    end
    sort!(plans; by=file -> file.source.path)
    plan = WorkspaceEditPlan(string(uuid4()), operation_scope(ctx), description, provenance, plans,
        utcstamp(), "", total, :prepared, nothing, nothing, ReentrantLock())
    encoded = bounded_canonical_json(workspace_plan_manifest(plan); maximum=2*1024^2, max_depth=16, max_nodes=32_000)
    plan.sha256 = digest(encoded)
    plan.bytes += ncodeunits(encoded)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:workspace_edit, "Workspace edit manager is closed"))
        while length(manager.order) >= limits.maximum_plans || manager.retained_bytes + plan.bytes > limits.maximum_retained_bytes
            candidate = findfirst(id -> manager.plans[id].status != :applying && manager.plans[id].status != :verifying, manager.order)
            candidate === nothing && throw(ShenScopeError(:capacity, "All retained workspace edit plans are busy"))
            id = manager.order[candidate]
            deleteat!(manager.order, candidate)
            retired = pop!(manager.plans, id)
            manager.retained_bytes -= retired.bytes
        end
        workspace_source_checkpoint(ctx)
        manager.plans[plan.id] = plan
        push!(manager.order, plan.id)
        manager.retained_bytes += plan.bytes
    end
    workspace_edit_plan_view(plan)
end

function owned_workspace_edit_plan(manager::WorkspaceEditManager, id::AbstractString, ctx::RuntimeContext)
    valid_id(workspace_edit_text(id, "workspace plan ID", 128))
    plan = lock(manager.mutex) do
        get(manager.plans, String(id), nothing)
    end
    plan === nothing && throw(ShenScopeError(:workspace_edit, "Workspace edit plan is absent or retired"))
    plan.scope == operation_scope(ctx) || throw(ShenScopeError(:permission, "Workspace edit plan belongs to another conversation or workspace"))
    plan
end

function workspace_edit_plan_view(plan::WorkspaceEditPlan)
    lock(plan.mutex) do
        manifest = workspace_plan_manifest(plan)
        merge!(manifest, Dict("plan_sha256" => plan.sha256, "status" => String(plan.status),
            "receipt" => deepcopy(plan.receipt), "verification" => deepcopy(plan.verification),
            "retention" => "bounded_memory", "automatic_replay" => false))
        manifest
    end
end

function list_workspace_edit_plans(manager::WorkspaceEditManager, ctx::RuntimeContext)
    authorize!(ctx, :read, "workspace.preview", ctx.root; reason="List this conversation's workspace edit proposals")
    plans = lock(manager.mutex) do
        [manager.plans[id] for id in reverse(manager.order) if manager.plans[id].scope == operation_scope(ctx)]
    end
    Dict("plans" => [Dict("plan_id" => plan.id, "plan_sha256" => plan.sha256,
        "title" => plan.title, "status" => String(plan.status), "files" => length(plan.files),
        "created_at" => plan.created_at) for plan in plans], "automatic_execution" => false)
end

function close_workspace_edits!(manager::WorkspaceEditManager)
    lock(manager.mutex) do
        manager.closed = true
        empty!(manager.plans)
        empty!(manager.order)
        manager.retained_bytes = 0
    end
    nothing
end
