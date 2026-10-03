mutable struct Workflow
    id::String
    root::String
    session_id::String
    scope::Symbol
    title::String
    created_at::String
    tasks::Dict{String,WorkRecord}
    children::Dict{String,Vector{String}}
    topological_order::Vector{String}
    journal::Journal
    revision::Int
    journal_bytes::Int
    mutex::ReentrantLock
end

function workflow_path(ctx::RuntimeContext, id::AbstractString)
    joinpath(ctx.state_dir, "workflows", digest(ctx.root), valid_id(id) * ".jsonl")
end

function check_workflow_scope(workflow::Workflow, ctx::RuntimeContext)
    workflow.root == ctx.root || throw(ShenScopeError(:permission, "Workflow belongs to another workspace"))
    workflow.scope == :workspace || workflow.session_id == ctx.session_id ||
        throw(ShenScopeError(:permission, "Workflow belongs to another session"))
    check_cancelled(ctx.cancellation)
    nothing
end

function empty_workflow(ctx::RuntimeContext, id::String)
    Workflow(id, ctx.root, ctx.session_id, :session, "", "",
        Dict{String,WorkRecord}(), Dict{String,Vector{String}}(), String[],
        Journal(workflow_path(ctx, id)), 0, 0, ReentrantLock())
end

function apply_workflow_record!(workflow::Workflow, record::AbstractDict)
    record["workflow_id"] == workflow.id && record["revision"] == workflow.revision + 1 ||
        throw(ShenScopeError(:storage, "Workflow revision mismatch"))
    kind = record["kind"]
    if kind == "workflow_created"
        workflow.revision == 0 || throw(ShenScopeError(:storage, "Duplicate workflow header"))
        record["root"] == workflow.root || throw(ShenScopeError(:storage, "Workflow root mismatch"))
        scope = Symbol(record["scope"])
        scope in (:session, :workspace) || throw(ShenScopeError(:storage, "Invalid workflow scope"))
        specifications = work_spec_from.(record["tasks"])
        order, children = validate_work_graph(specifications)
        workflow.session_id = valid_id(record["session_id"])
        workflow.scope = scope
        workflow.title = record["title"]
        workflow.created_at = record["created_at"]
        workflow.tasks = Dict(spec.id => WorkRecord(spec) for spec in specifications)
        workflow.topological_order = order
        workflow.children = children
    elseif kind == "workflow_mutated"
        workflow.revision > 0 || throw(ShenScopeError(:storage, "Workflow header is missing"))
        changes = Dict{String,WorkRecord}()
        for value in record["changes"]
            id = value["id"]
            haskey(workflow.tasks, id) && !haskey(changes, id) ||
                throw(ShenScopeError(:storage, "Invalid workflow task change"))
            next = work_runtime_from(workflow.tasks[id].spec, value)
            next.version > workflow.tasks[id].version || throw(ShenScopeError(:storage, "Task version did not advance"))
            changes[id] = next
        end
        merge!(workflow.tasks, changes)
    else
        throw(ShenScopeError(:storage, "Unknown workflow event"))
    end
    workflow.revision = record["revision"]
    workflow
end

function read_workflow_locked!(workflow::Workflow, ctx::RuntimeContext; force = false, repair = false)
    path = workflow.journal.path
    isfile(path) || throw(ShenScopeError(:tasks, "Workflow does not exist"))
    bytes = filesize(path)
    bytes <= MAX_WORKFLOW_JOURNAL_BYTES || throw(ShenScopeError(:storage, "Workflow journal exceeds capacity"))
    !force && workflow.revision > 0 && bytes == workflow.journal_bytes && return workflow
    candidate = empty_workflow(ctx, workflow.id)
    valid_bytes = Ref(0)
    records = journal_records(workflow.journal; valid_bytes)
    for record in records
        apply_workflow_record!(candidate, record)
    end
    candidate.revision > 0 || throw(ShenScopeError(:storage, "Workflow journal has no header"))
    check_workflow_scope(candidate, ctx)
    if repair && valid_bytes[] < bytes
        open(path, "r+") do io
            truncate(io, valid_bytes[])
            flush(io)
            sync_file(io)
        end
    end
    workflow.session_id = candidate.session_id
    workflow.scope = candidate.scope
    workflow.title = candidate.title
    workflow.created_at = candidate.created_at
    workflow.tasks = candidate.tasks
    workflow.children = candidate.children
    workflow.topological_order = candidate.topological_order
    workflow.revision = candidate.revision
    workflow.journal_bytes = valid_bytes[]
    workflow
end

function load_workflow(ctx::RuntimeContext, id::AbstractString)
    authorize!(ctx, :read, "tasks.load", ctx.root)
    workflow = empty_workflow(ctx, valid_id(id))
    lock(workflow.mutex) do
        store_lock(workflow.journal.path) do
            read_workflow_locked!(workflow, ctx; force = true)
        end
    end
end

function workflow_frame(workflow::Workflow, record::AbstractDict)
    canonical(Dict("schema" => 1, "sequence" => workflow.revision + 1,
        "record" => record, "sha256" => digest(canonical(record)))) * "\n"
end

function write_workflow_record_locked!(workflow::Workflow, record::AbstractDict)
    frame = workflow_frame(workflow, record)
    ncodeunits(frame) <= workflow.journal.max_record_bytes || throw(ShenScopeError(:storage, "Workflow event exceeds record capacity"))
    workflow.journal_bytes + ncodeunits(frame) <= MAX_WORKFLOW_JOURNAL_BYTES ||
        throw(ShenScopeError(:storage, "Workflow journal capacity reached"))
    path = workflow.journal.path
    open(path, "a") do io
        chmod(path, 0o600)
        write(io, frame)
        flush(io)
        sync_file(io)
    end
    workflow.journal_bytes += ncodeunits(frame)
    apply_workflow_record!(workflow, record)
    workflow
end

function create_workflow(ctx::RuntimeContext, specs::AbstractVector{WorkSpec};
        id = string(uuid4()), title = "Workflow", scope = :session)
    scope in (:session, :workspace) || throw(ShenScopeError(:tasks, "Unknown workflow scope"))
    title isa AbstractString && 1 <= ncodeunits(title) <= 512 || throw(ShenScopeError(:tasks, "Invalid workflow title"))
    validate_work_graph(specs)
    workflow = empty_workflow(ctx, valid_id(id))
    authorize!(ctx, :persistence, "tasks.create", workflow.journal.path; reason = "Create a durable task graph")
    record = Dict("kind" => "workflow_created", "workflow_id" => workflow.id,
        "revision" => 1, "root" => ctx.root, "session_id" => ctx.session_id,
        "scope" => String(scope), "title" => String(title), "created_at" => utcstamp(),
        "tasks" => work_spec_dict.(specs))
    frame = workflow_frame(workflow, record)
    ncodeunits(frame) <= workflow.journal.max_record_bytes || throw(ShenScopeError(:storage, "Workflow definition exceeds capacity"))
    store_lock(workflow.journal.path) do
        isfile(workflow.journal.path) && throw(ShenScopeError(:conflict, "Workflow already exists"))
        atomic_write(workflow.journal.path, frame)
        apply_workflow_record!(workflow, record)
        workflow.journal_bytes = ncodeunits(frame)
    end
    emit!(ctx, :workflow_created, Dict("workflow_id" => workflow.id, "tasks" => length(specs)))
    workflow
end

function mutate_workflow!(f::Function, workflow::Workflow, ctx::RuntimeContext; expected_revision = nothing, operation = "update")
    check_workflow_scope(workflow, ctx)
    authorize!(ctx, :persistence, "tasks.mutate", workflow.journal.path; reason = "Persist task scheduling and execution receipts")
    result, changed = lock(workflow.mutex) do
        store_lock(workflow.journal.path) do
            read_workflow_locked!(workflow, ctx; repair = true)
            expected_revision === nothing || expected_revision == workflow.revision ||
                throw(ShenScopeError(:conflict, "Workflow revision changed"))
            candidate = copy(workflow.tasks)
            changed = Set{String}()
            result = f(candidate, changed)
            if !isempty(changed)
                propagate_work_dependencies!(candidate, workflow.children, changed)
                values = [work_runtime_dict(candidate[id]) for id in sort!(collect(changed))]
                # Decode the entire candidate before writing any persistent bytes.
                for value in values
                    work_runtime_from(workflow.tasks[value["id"]].spec, value)
                end
                record = Dict("kind" => "workflow_mutated", "workflow_id" => workflow.id,
                    "revision" => workflow.revision + 1, "operation" => operation,
                    "timestamp" => utcstamp(), "changes" => values)
                write_workflow_record_locked!(workflow, record)
            end
            result, sort!(collect(changed))
        end
    end
    if !isempty(changed)
        emit!(ctx, :workflow_updated, Dict("workflow_id" => workflow.id, "revision" => workflow.revision,
            "operation" => operation, "changed_tasks" => changed))
    end
    result
end
