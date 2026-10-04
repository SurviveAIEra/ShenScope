function cli_agent_command(positional,flags,config,state_dir)
    command=first(positional)
    root=get(flags,"--root",pwd())
    policy=permissions_from_config(config)
    for (flag,category) in (("--allow-edit",:edit),("--allow-process",:process),("--allow-network",:network),("--allow-persistence",:persistence),("--allow-dynamic",:dynamic),("--allow-mcp",:mcp))
        get(flags,flag,false) && (policy.rules[category]=Allow)
    end
    provider=haskey(flags,"--script") ? scripted_provider(flags["--script"]) : provider_from_config(config)
    if provider isa HTTPProvider && !haskey(config,"model_routing") && isempty(get(ENV,provider.config.key_env,"")) && provider.config.protocol!=:ollama
        throw(ShenScopeError(:credentials,"Configure " * provider.config.key_env * " securely before using a live model"))
    end
    id=get(flags,"--session",string(uuid4()))
    ctx=RuntimeContext(root;session_id=id,state_dir,budget=BudgetLedger(limits_from_config(config)),
        permissions=policy,approve=cli_approval,sink=e->render_event(stdout,e;json=get(flags,"--json",false)))
    session=haskey(flags,"--session") ? load_session(state_dir,id) : new_session(ctx)
    tools=core_tools(;config,config_source=get(flags,"--config",config_path()))
    if !haskey(flags,"--script")
        model = only(tool for tool in tools if tool isa ModelsTool)
        provider = agent_model_provider(model;role=get(flags,"--model-role",nothing))
    end
    bind_models_provider!(tools,provider)
    if haskey(flags,"--script")
        workers = only(tool for tool in tools if tool isa TaskTool).manager
        workers.executor = WorkExecutor(;tools=collect(values(workers.executor.tools)),
            provider_factory=ctx->scripted_provider(flags["--script"]))
    end
    if command=="chat"
        length(positional)>=2 || throw(ShenScopeError(:input,"Task text required"))
        try
            run_agent!(provider,join(positional[2:end]," "),ctx;session,tools)
        finally
            for tool in tools;tool isa TaskTool && cleanup_tasks!(tool.manager);end
            for tool in tools
                tool isa MCPControlTool && cleanup_mcp!(tool.manager)
                tool isa SkillsTool && cleanup_skills!(tool.manager)
                tool isa HooksTool && cleanup_hooks!(tool.manager)
                tool isa ContextTool && cleanup_context!(tool.manager)
                tool isa AnalyzersTool && cleanup_analyzers!(tool.manager)
            tool isa ModelsTool && cleanup_models_tool!(tool)
            tool isa MemoryTool && cleanup_memory!(tool.manager)
                tool isa ProcessTool && cleanup_processes!(tool.manager,id)
            end
        end
        println(stderr,"Session: ",session.id)
    else
        return run_tui(provider,ctx,session;tools)
    end
    return 0
end
