function cli_analyzer_json(ctx::RuntimeContext,path::String,tool::String,reason::String)
    raw = read_scoped_text(ctx,ctx.root,path,8 * 1024^2;tool,reason)
    bounded_json_object(raw;maximum=8 * 1024^2,max_depth=24,max_nodes=100_000,error_code=:input)
end

function cli_analyzer_integer(flags,key::String,default::Int)
    value = tryparse(Int,String(get(flags,key,string(default))))
    value !== nothing && value >= 0 || throw(ShenScopeError(:input,key * " requires a nonnegative integer"))
    value
end

function cli_analyzers_command(positional,flags,config,state_dir)
    length(positional) >= 2 || throw(ShenScopeError(:input,"Use analyzers status|catalog|validate|evaluate|run|archive|promote|versions|inspect|restore|rollback|history|run-archive"))
    action = positional[2]
    direct = ("status","catalog","versions","history","inspect","restore","rollback")
    definitions = ("validate","evaluate","run","archive","promote")
    action in (direct...,definitions...,"run-archive") || throw(ShenScopeError(:input,"Unknown analyzer CLI action"))
    policy = permissions_from_config(config)
    for (flag,category) in (("--allow-process",:process),("--allow-dynamic",:dynamic),("--allow-persistence",:persistence))
        get(flags,flag,false) && (policy.rules[category]=Allow)
    end
    ctx = RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-analyzers"),
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    tool = AnalyzersTool()
    request = Dict{String,Any}("action"=>action)
    action in ("versions","history","inspect","restore","rollback","archive","promote","run-archive") &&
        (request["scope"] = String(get(flags,"--scope","project")))
    try
        if action in ("status","catalog")
            length(positional) == 2 || throw(ShenScopeError(:input,"Unexpected analyzer argument"))
        elseif action == "versions"
            2 <= length(positional) <= 3 || throw(ShenScopeError(:input,"Use analyzers versions [NAME]"))
            length(positional) == 3 && (request["name"] = positional[3])
            request["offset"] = cli_analyzer_integer(flags,"--offset",0)
            request["limit"] = cli_analyzer_integer(flags,"--limit",50)
        elseif action == "history"
            length(positional) == 3 || throw(ShenScopeError(:input,"Use analyzers history NAME"))
            request["name"] = positional[3];request["limit"] = cli_analyzer_integer(flags,"--limit",16)
        elseif action in ("inspect","restore","rollback","run-archive")
            expected = action == "restore" ? (3,4) : action == "run-archive" ? (4,5) : (4,4)
            expected[1] <= length(positional) <= expected[2] ||
                throw(ShenScopeError(:input,"Use analyzers " * action * " NAME VERSION [REQUEST.json for run-archive]"))
            request["name"] = positional[3]
            length(positional) >= 4 && (request["version"] = positional[4])
            action == "inspect" && (request["action"] = "archive_inspect")
            if action == "run-archive"
                restored = merge(request,Dict("action"=>"restore"))
                validate_schema(restored,tool_schema(tool));execute(tool,restored,ctx)
                delete!(request,"scope");request["action"] = "run"
            end
        else
            counts = action == "evaluate" ? (4,4) : action == "run" ? (3,4) : (3,3)
            counts[1] <= length(positional) <= counts[2] ||
                throw(ShenScopeError(:input,"Use analyzers " * action * " DEFINITION.json [INPUT.json for evaluate or REQUEST.json for run]"))
            definition = cli_analyzer_json(ctx,positional[3],"analysis.definition","Read analyzer definition and external fixtures")
            arguments = merge(definition,Dict("action"=>"register"))
            validate_schema(arguments,tool_schema(tool));registered = execute(tool,arguments,ctx)
            request["name"] = registered["definition"]["name"]
            if action == "evaluate"
                input = cli_analyzer_json(ctx,positional[4],"analysis.input","Read explicit analyzer data")
                Set(keys(input)) <= Set(["data","request"]) || throw(ShenScopeError(:input,"Unknown analyzer input field"))
                merge!(request,input)
            end
        end
        if action in ("promote","rollback")
            haskey(flags,"--expected-pointer") || throw(ShenScopeError(:input,"Promotion and rollback require --expected-pointer REVISION"))
            request["expected_pointer"] = cli_analyzer_integer(flags,"--expected-pointer",0)
        elseif action in ("run","run-archive")
            request["backend"] = String(get(flags,"--backend","tree_sitter"))
            input_position = action == "run" ? 4 : 5
            length(positional) == input_position && (request["request"] =
                cli_analyzer_json(ctx,positional[input_position],"analysis.request","Read explicit project analysis request"))
        end
        validate_schema(request,tool_schema(tool));result = execute(tool,request,ctx)
        println(canonical(result))
        action == "validate" && !result["passed"] ? 1 : 0
    finally
        cleanup_analyzers!(tool.manager)
        cleanup_projects!(tool.projects)
    end
end
