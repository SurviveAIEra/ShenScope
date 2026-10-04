function cli_models_command(positional,flags,config,state_dir)
    length(positional) >= 2 || throw(ShenScopeError(:input,"Use models status|list|refresh|inspect MODEL|count REQUEST.json"))
    action = positional[2]
    action in ("status","list","refresh","inspect","count") || throw(ShenScopeError(:input,"Unknown model CLI action"))
    arguments = Dict{String,Any}("action"=>action)
    if action in ("inspect","count")
        length(positional) == 3 || throw(ShenScopeError(:input,"Model inspection needs a model ID; token counting needs a request JSON file"))
        action == "inspect" && (arguments["model"] = positional[3])
    else
        length(positional) == 2 || throw(ShenScopeError(:input,"Unexpected model CLI argument"))
    end
    policy = permissions_from_config(config)
    get(flags,"--allow-network",false) && (policy.rules[:network] = Allow)
    context = RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-models"),
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    tool = ModelsTool(config)
    try
        if action in ("list","refresh")
            for (flag,key,default) in (("--offset","offset",0),("--limit","limit",50))
                value = tryparse(Int,String(get(flags,flag,string(default))))
                value !== nothing && value >= 0 || throw(ShenScopeError(:input,flag*" requires a nonnegative integer"))
                arguments[key] = value
            end
            action == "refresh" && (arguments["force"] = get(flags,"--force",false))
        elseif action == "count"
            raw = read_scoped_text(context,context.root,positional[3],8*1024^2;tool="models.input",reason="Read explicit assembled model request")
            arguments["request"] = bounded_json_object(raw;maximum=8*1024^2,max_depth=24,max_nodes=100_000,error_code=:arguments)
            arguments["mode"] = String(get(flags,"--count-mode","auto"))
        end
        validate_schema(arguments,tool_schema(tool));result = execute(tool,arguments,context)
        println(canonical(result));0
    finally
        cleanup_model_catalogs!(tool.manager)
    end
end
