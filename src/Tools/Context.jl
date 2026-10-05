struct ContextTool <: AbstractTool
    manager::ContextManager
end
ContextTool() = ContextTool(ContextManager())
tool_name(::ContextTool) = "context"
tool_description(::ContextTool) = "Inspect conversation context, recover digest-checked original messages and tool artifacts. Explicit compaction retains the transcript."
execution_mode(::ContextTool) = :exclusive

function tool_schema(::ContextTool)
    object_schema(Dict("action" => Dict("type" => "string", "enum" => ["status", "source", "artifact", "instructions", "compact"]),
        "message" => integer_schema(1), "sha256" => string_schema(; max=64),
        "start_byte" => integer_schema(1), "max_bytes" => integer_schema(4, 64 * 1024),
        "mode" => Dict("type" => "string", "enum" => ["extractive", "model"])); required=["action"])
end

function extra_context(tool::ContextTool, session::Session, ctx::RuntimeContext)
    bind_context_session!(tool.manager, session, ctx)
    ""
end

function context_manager_for_tools(tools)
    managers = [tool.manager for tool in tools if tool isa ContextTool]
    length(managers) <= 1 || throw(ShenScopeError(:extension, "Only one context controller is permitted"))
    isempty(managers) ? ContextManager() : only(managers)
end

function bind_request_sessions!(tools, session::Session, ctx::RuntimeContext)
    for tool in tools
        if tool isa SkillsTool
            bind_skills_session!(tool.manager, session, ctx)
            request = PermissionRequest("context-skills", :read, "skills.context", ctx.root, "Read active Skills")
            permission_decision(ctx.permissions, request) == Deny || restore_skills!(tool.manager, session, ctx)
        elseif tool isa ContextTool
            bind_context_session!(tool.manager, session, ctx)
        elseif tool isa PlanTool
            bind_agent_plan_session!(tool.manager, session, ctx)
        end
    end
end

function context_compact!(manager::ContextManager, session::Session, ctx::RuntimeContext,
        provider::AbstractModelProvider; mode="extractive", tools=AbstractTool[], max_output=min(2048,capabilities(provider).max_output))
    mode in ("extractive", "model") || throw(ShenScopeError(:arguments, "Unsupported compaction mode"))
    previous = get(session.metadata, "context_checkpoint", nothing)
    previous_id = previous isa AbstractDict ? get(previous, "id", nothing) : nothing
    request, projection = prepare_context!(provider, session, ctx; manager, tools,
        schemas=declaration.(active_tools(tools, ctx)), max_output, force=true, persist=mode == "extractive")
    checkpoint = projection.checkpoint
    (checkpoint === nothing || mode == "extractive" && checkpoint.id == previous_id) &&
        return Dict("compacted" => false, "projection" => projection_view(projection))
    if mode == "model"
        messages = context_snapshot(session, ctx)
        seed = build_context_checkpoint(session, messages, checkpoint.covered, manager.config)
        checkpoint = summarize_context_checkpoint!(provider, session, ctx, seed, manager.config; commit=false)
        projected, _ = context_projection_messages(messages, checkpoint)
        request, measure = context_request(provider, projection.messages[1].text, projected,
            request.tools, max_output, request.options, manager.config)
        context_fits(measure) || throw(ShenScopeError(:context_summary, "Summarized context does not fit the request capacity"))
        commit_context_checkpoint!(session, ctx, checkpoint)
        projection = ContextProjection(request.messages, measure, checkpoint, Dict{String,Any}[],
            projection.instructions, length(messages))
        lock(manager.mutex) do; manager.latest[(ctx.root, ctx.session_id)] = projection_view(projection); end
    end
    Dict("compacted" => true, "checkpoint" => checkpoint_view(checkpoint), "projection" => projection_view(projection))
end

function execute(tool::ContextTool, arguments::AbstractDict, ctx::RuntimeContext; user_requested=false,
        provider=nothing, tools=AbstractTool[])
    manager = tool.manager
    action = arguments["action"]
    valid = action == "source" ? Set(["action", "message", "sha256", "start_byte", "max_bytes"]) :
        action == "artifact" ? Set(["action", "sha256", "max_bytes"]) :
        action == "compact" ? Set(["action", "mode"]) : Set(["action"])
    all(key -> key in valid, keys(arguments)) || throw(ShenScopeError(:arguments, "Field does not apply to this context action"))
    if action == "status"
        authorize_context_read!(ctx, "context.status")
        return context_status(manager, ctx)
    elseif action == "source"
        haskey(arguments, "message") || throw(ShenScopeError(:arguments, "Original message index is required"))
        return context_source(manager, ctx, arguments["message"]; expected_sha256=get(arguments, "sha256", nothing),
            start_byte=get(arguments, "start_byte", 1), max_bytes=get(arguments, "max_bytes", 16 * 1024))
    elseif action == "artifact"
        haskey(arguments, "sha256") || throw(ShenScopeError(:arguments, "Output artifact digest is required"))
        return context_artifact(manager, ctx, arguments["sha256"]; max_bytes=get(arguments, "max_bytes", 64 * 1024))
    elseif action == "instructions"
        session = context_session!(manager, ctx)
        sources = load_project_instructions(ctx, context_snapshot(session, ctx), manager.config)
        return Dict("instructions" => [instruction_view(source; include_text=true) for source in sources])
    elseif action == "compact"
        user_requested || throw(ShenScopeError(:context_control, "Manual compaction requires an explicit user command"))
        provider isa AbstractModelProvider || throw(ShenScopeError(:context_control, "Manual compaction requires the configured model capability"))
        return context_compact!(manager, context_session!(manager, ctx), ctx, provider;
            mode=get(arguments, "mode", "extractive"), tools)
    end
    throw(ShenScopeError(:arguments, "Unknown context action"))
end
