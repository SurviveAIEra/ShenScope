function retain_validation_report!(manager::ProjectValidationManager, report::AbstractDict, ctx::RuntimeContext)
    encoded = bounded_canonical_json(report; maximum=manager.limits.maximum_report_bytes, max_depth=32, max_nodes=100_000)
    id = report["validation_id"]
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:validation, "Project validation manager is closed"))
        while length(manager.order) >= manager.limits.maximum_reports ||
                manager.retained_bytes+ncodeunits(encoded) > manager.limits.maximum_retained_bytes
            isempty(manager.order) && throw(ShenScopeError(:capacity, "Validation report cannot be retained"))
            retired = popfirst!(manager.order)
            manager.retained_bytes -= ncodeunits(canonical(manager.reports[retired]))
            delete!(manager.reports, retired)
            delete!(manager.scopes, retired)
        end
        manager.reports[id] = deepcopy(Dict{String,Any}(report))
        manager.scopes[id] = operation_scope(ctx)
        push!(manager.order, id)
        manager.retained_bytes += ncodeunits(encoded)
    end
    nothing
end

function read_validation_report(manager::ProjectValidationManager, id::AbstractString, ctx::RuntimeContext)
    valid_id(workspace_edit_text(id, "validation receipt ID", 128))
    authorize!(ctx, :read, "validation", ctx.root; reason="Read an owned compiler or project check receipt")
    lock(manager.mutex) do
        haskey(manager.reports, id) || throw(ShenScopeError(:validation, "Validation receipt is absent or retired"))
        manager.scopes[id] == operation_scope(ctx) || throw(ShenScopeError(:permission, "Validation receipt belongs to another conversation"))
        deepcopy(manager.reports[id])
    end
end

function list_validation_reports(manager::ProjectValidationManager, ctx::RuntimeContext)
    authorize!(ctx, :read, "validation", ctx.root; reason="List this conversation's project check receipts")
    lock(manager.mutex) do
        Dict("reports" => [Dict("validation_id" => id, "sha256" => manager.reports[id]["sha256"],
            "label" => manager.reports[id]["label"], "outcome" => manager.reports[id]["outcome"],
            "created_at" => manager.reports[id]["created_at"]) for id in reverse(manager.order)
            if manager.scopes[id] == operation_scope(ctx)], "retention" => "bounded_memory", "automatic_execution" => false)
    end
end

function close_validation!(manager::ProjectValidationManager)
    lock(manager.mutex) do
        manager.closed = true
        empty!(manager.reports)
        empty!(manager.order)
        empty!(manager.scopes)
        manager.retained_bytes = 0
    end
    nothing
end
