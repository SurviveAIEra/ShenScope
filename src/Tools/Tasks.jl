mutable struct WorkRun
    id::String
    workflow_id::String
    context::RuntimeContext
    status::Symbol
    result::Any
    error::Union{Nothing,String}
    task::Union{Nothing,Task}
end

mutable struct TaskManager
    executor::WorkExecutor
    workflows::Dict{String,Workflow}
    jobs::Dict{String,WorkRun}
    mutex::ReentrantLock
end
TaskManager(executor::WorkExecutor) = TaskManager(executor, Dict{String,Workflow}(), Dict{String,WorkRun}(), ReentrantLock())

struct TaskTool <: AbstractTool
    manager::TaskManager
end
TaskTool(executor::WorkExecutor = WorkExecutor()) = TaskTool(TaskManager(executor))
tool_name(::TaskTool) = "tasks"
tool_description(::TaskTool) = "Create and run durable dependency graphs, inspect receipts, cancel work and explicitly reconcile uncertain external effects."
execution_mode(::TaskTool) = :exclusive

function tool_schema(::TaskTool)
    object_schema(Dict(
        "action" => Dict("type" => "string", "enum" => ["create", "list", "status", "tasks", "get", "run", "cancel", "recover", "reconcile"]),
        "workflow_id" => string_schema(; max = 128), "task_id" => string_schema(; max = 128),
        "title" => string_schema(; max = 512), "scope" => Dict("type" => "string", "enum" => ["session", "workspace"]),
        "definitions" => Dict("type" => "array", "minItems" => 1, "maxItems" => MAX_WORKFLOW_TASKS,
            "items" => Dict("type" => "object")),
        "ids" => Dict("type" => "array", "maxItems" => MAX_WORKFLOW_TASKS, "items" => string_schema(; max = 128)),
        "cascade" => Dict("type" => "boolean"), "materialize" => Dict("type" => "boolean"),
        "status" => Dict("type" => "string", "enum" => collect(values(WORK_STATUS_NAMES))),
        "offset" => integer_schema(0, 10000), "limit" => integer_schema(1, 200),
        "concurrency" => integer_schema(1, 16), "max_seconds" => Dict("type" => "number", "minimum" => 0.1, "maximum" => 86400),
        "wait_for_retries" => Dict("type" => "boolean"),
        "disposition" => Dict("type" => "string", "enum" => ["succeeded", "failed", "retry"]),
        "evidence" => string_schema(; max = 4096), "result" => Dict(),
        "expected_revision" => integer_schema(1), "expected_version" => integer_schema(1)); required = ["action"])
end

function task_argument(arguments::AbstractDict, key::String)
    value = get(arguments, key, nothing)
    value isa AbstractString && !isempty(value) || throw(ShenScopeError(:arguments, "Task action requires " * key))
    value
end

function managed_workflow(manager::TaskManager, ctx::RuntimeContext, id::String)
    key = digest(ctx.root) * ":" * valid_id(id)
    current = lock(manager.mutex) do; get(manager.workflows, key, nothing); end
    if current === nothing
        current = load_workflow(ctx, id)
        lock(manager.mutex) do
            length(manager.workflows) >= 128 && delete!(manager.workflows, first(sort!(collect(keys(manager.workflows)))))
            manager.workflows[key] = current
        end
    end
    check_workflow_scope(current, ctx)
    current
end

function cache_workflow!(manager::TaskManager, workflow::Workflow)
    lock(manager.mutex) do
        key = digest(workflow.root) * ":" * workflow.id
        if !haskey(manager.workflows, key) && length(manager.workflows) >= 128
            delete!(manager.workflows, first(sort!(collect(keys(manager.workflows)))))
        end
        manager.workflows[key] = workflow
    end
    workflow
end

function execute(tool::TaskTool, arguments::AbstractDict, ctx::RuntimeContext)
    action = arguments["action"]
    manager = tool.manager
    if action == "create"
        definitions = get(arguments, "definitions", nothing)
        definitions isa AbstractVector || throw(ShenScopeError(:arguments, "Task definitions are required"))
        specifications = WorkSpec[work_spec_from(value) for value in definitions]
        workflow = create_workflow(ctx, specifications; id = get(arguments, "workflow_id", string(uuid4())),
            title = get(arguments, "title", "Workflow"), scope = Symbol(get(arguments, "scope", "session")))
        cache_workflow!(manager, workflow)
        return workflow_status(workflow, ctx)
    elseif action == "list"
        return list_workflows(ctx; offset = get(arguments, "offset", 0), limit = get(arguments, "limit", 50))
    end
    workflow = managed_workflow(manager, ctx, task_argument(arguments, "workflow_id"))
    if action == "status"
        return workflow_status(workflow, ctx)
    elseif action == "tasks"
        return workflow_tasks(workflow, ctx; status = get(arguments, "status", nothing),
            offset = get(arguments, "offset", 0), limit = get(arguments, "limit", 50))
    elseif action == "get"
        return workflow_task(workflow, ctx, task_argument(arguments, "task_id"); materialize = get(arguments, "materialize", false))
    elseif action == "run"
        return run_workflow!(manager.executor, workflow, ctx; concurrency = get(arguments, "concurrency", 4),
            max_seconds = get(arguments, "max_seconds", 3600.0), wait_for_retries = get(arguments, "wait_for_retries", true))
    elseif action == "cancel"
        ids = get(arguments, "ids", collect(keys(workflow.tasks)))
        return cancel_work!(workflow, ctx, ids; cascade = get(arguments, "cascade", true),
            expected_revision = get(arguments, "expected_revision", nothing))
    elseif action == "recover"
        return recover_workflow!(workflow, ctx)
    elseif action == "reconcile"
        return reconcile_work!(workflow, ctx, task_argument(arguments, "task_id");
            disposition = Symbol(task_argument(arguments, "disposition")), evidence = task_argument(arguments, "evidence"),
            result = get(arguments, "result", nothing), expected_version = get(arguments, "expected_version", nothing))
    end
    throw(ShenScopeError(:arguments, "Unknown task action"))
end

function work_run_view(run::WorkRun)
    Dict("id" => run.id, "workflow_id" => run.workflow_id, "session_id" => run.context.session_id,
        "status" => String(run.status), "result" => deepcopy(run.result), "error" => run.error)
end

function cleanup_tasks!(manager::TaskManager)
    jobs = lock(manager.mutex) do; collect(values(manager.jobs)); end
    for job in jobs; cancel!(job.context.cancellation, "Task manager stopped"); end
    for job in jobs
        job.task !== nothing && job.task !== current_task() && wait(job.task)
    end
    for tool in values(manager.executor.tools)
        tool isa ProjectTool && cleanup_projects!(tool.manager)
    end
    nothing
end
