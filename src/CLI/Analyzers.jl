function cli_analyzers_command(positional,flags,config,state_dir)
    length(positional) >= 2 || throw(ShenScopeError(:input,"Use analyzers status|validate|evaluate"))
    action = positional[2]
    action in ("status","validate","evaluate") || throw(ShenScopeError(:input,"Session registration is exposed by the agent tool; CLI validates a definition in this invocation"))
    policy = permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-dynamic",false) && (policy.rules[:dynamic]=Allow)
    ctx = RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-analyzers"),
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    tool = AnalyzersTool()
    try
        if action == "status"
            length(positional) == 2 || throw(ShenScopeError(:input,"Unexpected analyzer status argument"))
            println(canonical(execute(tool,Dict("action"=>"status"),ctx)))
            return 0
        end
        length(positional) == (action == "evaluate" ? 4 : 3) ||
            throw(ShenScopeError(:input,"Use analyzers validate DEFINITION.json or analyzers evaluate DEFINITION.json INPUT.json"))
        raw = read_scoped_text(ctx,ctx.root,positional[3],8 * 1024^2;tool="analysis.definition",reason="Read analyzer definition and external fixtures")
        definition = bounded_json_object(raw;maximum=8 * 1024^2,max_depth=24,max_nodes=100_000,error_code=:input)
        arguments = merge(definition,Dict("action"=>"register"))
        validate_schema(arguments,tool_schema(tool));registered=execute(tool,arguments,ctx)
        name = registered["definition"]["name"]
        request = Dict{String,Any}("action"=>action,"name"=>name)
        if action == "evaluate"
            input_raw = read_scoped_text(ctx,ctx.root,positional[4],8 * 1024^2;tool="analysis.input",reason="Read explicit analyzer data")
            input = bounded_json_object(input_raw;maximum=8 * 1024^2,max_depth=24,max_nodes=100_000,error_code=:input)
            Set(keys(input)) <= Set(["data","request"]) || throw(ShenScopeError(:input,"Unknown analyzer input field"))
            merge!(request,input)
        end
        validate_schema(request,tool_schema(tool));result=execute(tool,request,ctx)
        println(canonical(result))
        action == "validate" && !result["passed"] ? 1 : 0
    finally
        cleanup_analyzers!(tool.manager)
    end
end
