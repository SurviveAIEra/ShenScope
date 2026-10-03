struct WorkExecutor
    tools::Dict{String,AbstractTool}
    provider_factory::Function
end

function WorkExecutor(; tools = core_tools(; tasks = false), provider_factory = ctx -> provider_from_config(load_config()))
    registry = Dict{String,AbstractTool}()
    process = ProcessTool()
    for tool in tools
        name = tool_name(tool)
        name == "tasks" && continue
        haskey(registry, name) && throw(ShenScopeError(:tasks, "Duplicate worker tool"))
        builtin = get(Dict("read" => ReadTool, "search" => SearchTool, "memory" => MemoryTool,
            "project" => ProjectTool, "git" => GitTool, "diagnostics" => DiagnosticsTool), name, nothing)
        builtin === nothing || tool isa builtin || throw(ShenScopeError(:tasks, "Worker safety names require their Core implementation"))
        registry[name] = tool isa ProcessTool ? process : tool isa GitTool ? GitTool(process) : tool
    end
    WorkExecutor(registry, provider_factory)
end

function worker_tool(executor::WorkExecutor, operation::String)
    tool = get(executor.tools, operation, nothing)
    tool === nothing && throw(ShenScopeError(:tasks, "Worker operation is not registered"))
    tool
end

function execute_worker_tool(executor::WorkExecutor, operation::String, arguments::AbstractDict, ctx::RuntimeContext)
    tool = worker_tool(executor, operation)
    operation == "process" && get(arguments, "action", "") != "run" &&
        throw(ShenScopeError(:arguments, "Durable workers require foreground process completion"))
    validate_tool_arguments(tool, arguments)
    check_cancelled(ctx.cancellation)
    id = string(uuid4())
    emit!(ctx, :tool_started, Dict("id" => id, "name" => operation, "worker" => true))
    result = nothing
    try
        result = with_context(() -> execute(tool, arguments, ctx), ctx)
        success = is_successful_tool_result(tool, result)
        success || throw(ShenScopeError(:tool_failed, "Worker tool reported a failure"))
        emit!(ctx, :tool_completed, Dict("id" => id, "name" => operation, "ok" => success,
            "worker" => true, "value" => result))
        result
    catch error
        emit!(ctx, :tool_completed, Dict("id" => id, "name" => operation, "ok" => false,
            "worker" => true, "value" => result, "error" => error isa ShenScopeError ? sprint(showerror, error) : "Worker tool failed"))
        rethrow()
    end
end

function execute_work(executor::WorkExecutor, workflow::Workflow, record::WorkRecord, ctx::RuntimeContext)
    arguments = resolve_work_arguments(workflow, record, ctx)
    spec = record.spec
    if spec.kind == :tool
        return execute_worker_tool(executor, spec.operation, arguments, ctx)
    elseif spec.kind == :test
        spec.operation == "process" || throw(ShenScopeError(:tasks, "Test workers require process operation"))
        get(arguments, "action", "run") == "run" || throw(ShenScopeError(:tasks, "Test workers require a foreground process"))
        result = execute_worker_tool(executor, "process", arguments, ctx)
        get(result, "timed_out", false) && throw(ShenScopeError(:timeout, "Test process timed out"))
        get(result, "exit_code", -1) == 0 || throw(ShenScopeError(:test_failed, "Test process reported a failure"))
        return result
    elseif spec.kind == :index
        spec.operation in ("build", "update") || throw(ShenScopeError(:tasks, "Unknown index worker operation"))
        arguments["action"] = spec.operation
        return execute_worker_tool(executor, "project", arguments, ctx)
    elseif spec.kind == :analysis
        spec.operation in ("impact", "test_selection", "architecture") || throw(ShenScopeError(:tasks, "Unknown analysis worker operation"))
        arguments["action"] = spec.operation
        return execute_worker_tool(executor, "project", arguments, ctx)
    elseif spec.kind == :model
        spec.operation == "agent" || throw(ShenScopeError(:tasks, "Unknown model worker operation"))
        validate_schema(arguments, object_schema(Dict("prompt" => string_schema(; max = MAX_WORK_ARGUMENT_BYTES))))
        # Each attempt owns a session. A lost attempt is never silently resumed.
        session_id = "work-" * digest(workflow.id * ":" * spec.id * ":" * string(record.attempts))[1:40]
        modelsink = event -> ctx.sink(AgentEvent(event.sequence, event.kind, ctx.session_id,
            event.trace_id, event.timestamp, event.payload isa AbstractDict ?
                merge(event.payload, Dict("worker_session_id" => session_id)) : event.payload))
        modelctx = child_context(ctx; session_id, sink = modelsink)
        session = new_session(modelctx)
        session_record!(session, "metadata", Dict("workflow_id" => workflow.id,
            "task_id" => spec.id, "attempt" => record.attempts, "parent_session_id" => ctx.session_id))
        provider = executor.provider_factory(modelctx)
        try
            run_agent!(provider, arguments["prompt"], modelctx; session, tools = collect(values(executor.tools)))
        finally
            cleanup_executor!(executor, session_id)
        end
        messages = [message for message in session.messages if message.role == :assistant && !isempty(message.text)]
        return Dict("session_id" => session.id, "status" => String(session.status),
            "text" => isempty(messages) ? "" : last(messages).text)
    end
    throw(ShenScopeError(:tasks, "Worker kind is not supported"))
end

function worker_failure(error, spec::WorkSpec; interrupted = false)
    code = error isa ShenScopeError ? error.code : :internal
    message = error isa ShenScopeError ? cliptext(error.message, 4096) : "Task execution failed: " * string(nameof(typeof(error)))
    retryable = error isa ShenScopeError && error.retryable || code in (:network, :timeout, :rate_limit, :provider_unavailable, :process)
    # External effects cannot be rolled back by changing a journal record.
    uncertain = code == :mcp_outcome_uncertain || !spec.safe_retry && (interrupted || code in (:cancelled, :timeout, :lease_lost))
    WorkFailure(code, message, retryable, uncertain)
end

function cleanup_executor!(executor::WorkExecutor, session_id::String)
    for tool in values(executor.tools)
        tool isa ProcessTool && cleanup_processes!(tool.manager, session_id)
        tool isa MCPControlTool && cleanup_mcp!(tool.manager; session_id)
    end
    nothing
end
