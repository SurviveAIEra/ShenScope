function cli_testing_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Use tests discover, run CANDIDATE_ID or custom --argv JSON"))
    action=positional[2];action in ("discover","run","custom") || throw(ShenScopeError(:input,"Unknown project tests command"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());session_id=get(flags,"--session",string(uuid4())),state_dir,
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),sandbox=sandbox_from_config(config),approve=cli_approval)
    tool=TestingTool();args=Dict{String,Any}("action"=>action)
    for (option,key,parser) in (("--timeout","timeout",Float64),("--output-limit","output_limit",Int))
        haskey(flags,option) && (args[key]=parse(parser,flags[option]))
    end
    try
        if action in ("discover","run")
            length(positional)==(action=="run" ? 3 : 2) || throw(ShenScopeError(:input,"Use tests discover or tests run CANDIDATE_ID"))
            scopes=haskey(flags,"--scope-paths") ? split(flags["--scope-paths"],',') : ["."]
            catalog=execute(tool,Dict("action"=>"discover","scopes"=>scopes),ctx)
            if action=="discover"
                isempty(setdiff(keys(args),["action"])) || throw(ShenScopeError(:input,"Discovery does not accept execution limits"))
                println(canonical(catalog));return 0
            end
            args["catalog_id"]=catalog["catalog_id"];args["candidate_id"]=positional[3]
        else
            length(positional)==2 && haskey(flags,"--argv") || throw(ShenScopeError(:input,"Use tests custom --argv '[\"runner\",\"argument\"]'"))
            args["argv"]=parsejson(flags["--argv"]);args["cwd"]=get(flags,"--cwd",".")
            args["framework"]=get(flags,"--framework","raw");args["label"]=get(flags,"--title","Explicit test command")
        end
        value=execute(tool,args,ctx);println(canonical(value))
        is_successful_tool_result(tool,value) ? 0 : 1
    finally
        close_operations!(tool.operations);cleanup_project_tests!(tool.manager)
    end
end

function terminal_testing_command!(state::TerminalState,prompt::AbstractString,ctx::RuntimeContext,tools)
    words=split(prompt);tool=only(value for value in tools if value isa TestingTool)
    if first(words)=="/tests"
        length(words)==1 || throw(ShenScopeError(:input,"Use /tests to discover test commands"))
        value=execute(tool,Dict("action"=>"discover"),ctx)
        terminal_push!(state,"Discovered "*string(length(value["candidates"]))*" test command candidates; none executed.")
        for candidate in value["candidates"]
            terminal_push!(state,candidate["label"])
            terminal_push!(state,candidate["id"])
        end
        terminal_push!(state,"Select with /test CANDIDATE_ID. Project declarations will be checked again before execution.")
        terminal_push!(state,"Discovery status: "*value["coverage"]["status"]*"; this is not a complete project inventory.")
    elseif first(words)=="/test"
        length(words)==2 || throw(ShenScopeError(:input,"Use /test CANDIDATE_ID"))
        # Re-discovery preserves marker-bound candidate identity and does not
        # rely on a hidden latest-catalog pointer shared between conversations.
        catalog=execute(tool,Dict("action"=>"discover"),ctx)
        value=execute(tool,Dict("action"=>"run","catalog_id"=>catalog["catalog_id"],"candidate_id"=>String(words[2])),ctx)
        terminal_push!(state,"Test command: "*value["outcome"]*" · exit "*string(value["exit_code"]))
        for case in value["parsed"]["cases"];terminal_push!(state,"["*case["status"]*"] "*case["name"]);end
        for frame in value["parsed"]["frames"];terminal_push!(state,frame["path"]*":"*string(frame["line"]));end
        terminal_push!(state,"Case outcomes are framework reports; a successful command does not establish whole-project coverage.")
    else
        throw(ShenScopeError(:input,"Unknown terminal test command"))
    end
    nothing
end
