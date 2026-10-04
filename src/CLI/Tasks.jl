function cli_tasks_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Task action required"))
    policy=permissions_from_config(config)
    for (flag,category) in (("--allow-edit",:edit),("--allow-process",:process),("--allow-network",:network),("--allow-persistence",:persistence),("--allow-dynamic",:dynamic),("--allow-mcp",:mcp))
        get(flags,flag,false) && (policy.rules[category]=Allow)
    end
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-tasks"),
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    action=positional[2];args=Dict{String,Any}("action"=>action)
    if action=="create"
        length(positional)==3 || throw(ShenScopeError(:input,"Use tasks create DEFINITION.json"))
        path=workspace_path(ctx.root,positional[3];must_exist=true)
        authorize!(ctx,:read,"tasks.definition",path)
        filesize(path)<=8*1024*1024 || throw(ShenScopeError(:input,"Workflow definition exceeds limit"))
        definition=parsejson(read(path,String))
        definition isa AbstractDict || throw(ShenScopeError(:input,"Workflow definition must be an object"))
        merge!(args,definition);args["action"]="create"
    elseif action!="list"
        length(positional)>=3 || throw(ShenScopeError(:input,"Workflow ID required"))
        args["workflow_id"]=positional[3]
        if action in ("get","reconcile")
            length(positional)>=4 || throw(ShenScopeError(:input,"Task ID required"))
            args["task_id"]=positional[4]
            action=="get" && (args["materialize"]=true)
            if action=="reconcile"
                length(positional)>=6 || throw(ShenScopeError(:input,"Reconciliation requires disposition and evidence"))
                args["disposition"]=positional[5];args["evidence"]=join(positional[6:end]," ")
            end
        elseif action=="cancel" && length(positional)>3
            args["ids"]=positional[4:end]
        end
    end
    worker_tools=core_tools(;tasks=false,config)
    if haskey(flags,"--script")
        factory=ctx->scripted_provider(flags["--script"])
    else
        model = only(entry for entry in worker_tools if entry isa ModelsTool)
        factory=ctx->agent_model_provider(model;role=get(flags,"--model-role",model_worker_role(model)))
    end
    tool=TaskTool(WorkExecutor(;tools=worker_tools,provider_factory=factory))
    try
        validate_schema(args,tool_schema(tool));println(canonical(execute(tool,args,ctx)))
    finally
        cleanup_tasks!(tool.manager)
        for entry in worker_tools;entry isa ModelsTool && cleanup_models_tool!(entry);end
    end
    return 0
end
