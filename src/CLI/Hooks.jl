function cli_hooks_command(positional::Vector{String}, flags::AbstractDict, config::AbstractDict, state_dir::String)
    length(positional) >= 2 || throw(ShenScopeError(:input, "Use hooks list, reload, recent, source or test"))
    action = positional[2]
    arguments = Dict{String,Any}("action"=>action)
    action in ("source", "test") && length(positional) != 3 && throw(ShenScopeError(:input, "Hook name or source ID required"))
    length(positional) == 3 && (arguments["name"]=positional[3])
    policy = permissions_from_config(config)
    get(flags, "--allow-process", false) && (policy.rules[:process]=Allow)
    ctx = RuntimeContext(get(flags, "--root", pwd());session_id=get(flags, "--session", string(uuid4())),state_dir,
        permissions=policy,sandbox=sandbox_from_config(config),budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    manager = HookManager(config;config_source=get(flags, "--config", config_path()))
    tool = HooksTool(manager)
    try
        validate_tool_arguments(tool, arguments)
        result=with_context(()->execute(tool, arguments, ctx;user_requested=true), ctx)
        println(canonical(result))
        action == "test" && !(result["status"] in ("complete","blocked")) ? 2 : 0
    finally
        cleanup_hooks!(manager)
    end
end
