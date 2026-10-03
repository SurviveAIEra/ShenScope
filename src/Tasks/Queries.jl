function read_workflow(f::Function, workflow::Workflow, ctx::RuntimeContext)
    check_workflow_scope(workflow, ctx)
    authorize!(ctx, :read, "tasks.query", ctx.root)
    lock(workflow.mutex) do
        store_lock(workflow.journal.path) do
            read_workflow_locked!(workflow, ctx)
            f(workflow)
        end
    end
end

function workflow_status(workflow::Workflow, ctx::RuntimeContext)
    read_workflow(workflow, ctx) do current
        counts = Dict(label => 0 for label in values(WORK_STATUS_NAMES))
        for record in values(current.tasks)
            counts[WORK_STATUS_NAMES[record.status]] += 1
        end
        state = counts["uncertain"] > 0 ? "needs_reconciliation" :
            counts["running"] > 0 ? "running" : counts["ready"] > 0 ? "ready" :
            counts["retry_waiting"] > 0 ? "waiting_retry" : counts["pending"] > 0 ? "waiting_dependencies" :
            counts["failed"] + counts["blocked"] > 0 ? "failed" : counts["cancelled"] > 0 ? "cancelled" : "succeeded"
        Dict("id" => current.id, "title" => current.title, "scope" => String(current.scope),
            "session_id" => current.session_id, "revision" => current.revision,
            "created_at" => current.created_at, "status" => state, "counts" => counts,
            "journal_bytes" => current.journal_bytes, "task_count" => length(current.tasks))
    end
end

function workflow_tasks(workflow::Workflow, ctx::RuntimeContext; status = nothing,
        offset = 0, limit = 50, include_arguments = false, include_result = false)
    offset isa Integer && !(offset isa Bool) && 0 <= offset <= MAX_WORKFLOW_TASKS &&
        limit isa Integer && !(limit isa Bool) && 1 <= limit <= 200 || throw(ShenScopeError(:tasks, "Invalid task page"))
    selected_status = status === nothing ? nothing : work_status(status)
    read_workflow(workflow, ctx) do current
        ids = [id for id in current.topological_order if selected_status === nothing || current.tasks[id].status == selected_status]
        selected = ids[min(offset + 1, length(ids) + 1):min(offset + limit, length(ids))]
        Dict("workflow_id" => current.id, "revision" => current.revision, "total" => length(ids),
            "offset" => offset, "items" => [work_view(current.tasks[id]; include_arguments, include_result) for id in selected])
    end
end

function workflow_task(workflow::Workflow, ctx::RuntimeContext, id::AbstractString; materialize = false)
    record = read_workflow(workflow, ctx) do current
        value = get(current.tasks, valid_id(id), nothing)
        value === nothing && throw(ShenScopeError(:tasks, "Task does not exist"))
        deepcopy(value)
    end
    view = work_view(record; include_arguments = true)
    materialize && record.status == WorkSucceeded && (view["result"] = materialize_work_result(workflow, record, ctx))
    view
end

function list_workflows(ctx::RuntimeContext; offset = 0, limit = 50)
    offset isa Integer && !(offset isa Bool) && 0 <= offset <= 10000 &&
        limit isa Integer && !(limit isa Bool) && 1 <= limit <= 200 || throw(ShenScopeError(:tasks, "Invalid workflow page"))
    authorize!(ctx, :read, "tasks.list", ctx.root)
    directory = dirname(workflow_path(ctx, "list"))
    isdir(directory) || return Dict("total" => 0, "items" => Any[])
    names = sort!(filter(name -> endswith(name, ".jsonl"), readdir(directory)))
    length(names) <= 10000 || throw(ShenScopeError(:capacity, "Workflow directory exceeds listing capacity"))
    visible = Dict{String,Any}[]
    for name in names
        try
            workflow = load_workflow(ctx, name[1:end-6])
            push!(visible, workflow_status(workflow, ctx))
        catch error
            error isa ShenScopeError && error.code == :permission || rethrow()
        end
    end
    selected = visible[min(offset + 1, length(visible) + 1):min(offset + limit, length(visible))]
    Dict("total" => length(visible), "offset" => offset, "items" => selected)
end
