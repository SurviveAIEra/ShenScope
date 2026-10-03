function cli_context_command(positional::Vector{String}, flags::AbstractDict, config::AbstractDict, state_dir::String)
    length(positional) >= 2 || throw(ShenScopeError(:input, "Use context status, instructions, source, artifact or compact"))
    haskey(flags, "--session") || throw(ShenScopeError(:input, "A context operation requires --session"))
    action = positional[2]
    arguments = Dict{String,Any}("action" => action)
    if action == "source"
        length(positional) == 3 || throw(ShenScopeError(:input, "Source message index required"))
        index = tryparse(Int, positional[3])
        index === nothing && throw(ShenScopeError(:input, "Source message index must be an integer"))
        arguments["message"] = index
    elseif action == "artifact"
        length(positional) == 3 || throw(ShenScopeError(:input, "Artifact SHA-256 required"))
        arguments["sha256"] = positional[3]
    elseif action == "compact"
        length(positional) <= 3 || throw(ShenScopeError(:input, "Use compact extractive or compact model"))
        arguments["mode"] = length(positional) == 3 ? positional[3] : "extractive"
    else
        length(positional) == 2 || throw(ShenScopeError(:input, "Unexpected context argument"))
    end
    policy = permissions_from_config(config)
    get(flags, "--allow-persistence", false) && (policy.rules[:persistence] = Allow)
    get(flags, "--allow-network", false) && (policy.rules[:network] = Allow)
    ctx = RuntimeContext(get(flags, "--root", pwd()); session_id=flags["--session"], state_dir,
        permissions=policy, budget=BudgetLedger(limits_from_config(config)), approve=cli_approval)
    session = load_session(state_dir, ctx.session_id)
    tools = core_tools(; config, config_source=get(flags, "--config", config_path()))
    tool = only(tool for tool in tools if tool isa ContextTool)
    bind_context_session!(tool.manager, session, ctx)
    provider = haskey(flags, "--script") ? scripted_provider(flags["--script"]) : provider_from_config(config)
    try
        validate_tool_arguments(tool, arguments)
        result = with_context(() -> execute(tool, arguments, ctx; user_requested=true, provider, tools), ctx)
        println(canonical(result))
        0
    finally
        for entry in tools
            entry isa ContextTool && cleanup_context!(entry.manager)
            entry isa SkillsTool && cleanup_skills!(entry.manager)
            entry isa HooksTool && cleanup_hooks!(entry.manager)
            entry isa MCPControlTool && cleanup_mcp!(entry.manager)
            entry isa TaskTool && cleanup_tasks!(entry.manager)
        end
    end
end
