function cli_testing_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Use tests discover, run, custom, saved, show, rename or forget"))
    action=positional[2];action in ("discover","run","custom","saved","show","rename","forget") || throw(ShenScopeError(:input,"Unknown project tests command"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());session_id=get(flags,"--session","cli-tests"),state_dir,
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),sandbox=sandbox_from_config(config),approve=cli_approval)
    tool=TestingTool();args=Dict{String,Any}("action"=>action)
    save=get(flags,"--save",false)
    save && !(action in ("run","custom")) && throw(ShenScopeError(:input,"--save applies only to tests run or custom"))
    revision=nothing
    if save || action in ("rename","forget")
        haskey(flags,"--expected-revision") || throw(ShenScopeError(:input,"Saving or changing test history requires --expected-revision N"))
        revision=project_test_history_revision(parse(Int,flags["--expected-revision"]))
    end
    for (option,key,parser) in (("--timeout","timeout",Float64),("--output-limit","output_limit",Int))
        haskey(flags,option) && (args[key]=parse(parser,flags[option]))
    end
    try
        if action in ("saved","show","rename","forget")
            length(positional)==(action=="saved" ? 2 : 3) || throw(ShenScopeError(:input,"Use tests saved or tests show/rename/forget RUN_ID"))
            isempty(setdiff(keys(args),["action"])) || throw(ShenScopeError(:input,"Saved history commands do not accept execution limits"))
            args["action"]=Dict("saved"=>"history_list","show"=>"history_get","rename"=>"history_label","forget"=>"history_delete")[action]
            action=="saved" ? (args["limit"]=parse(Int,get(flags,"--limit","16"));args["offset"]=parse(Int,get(flags,"--offset","0"))) : (args["run_id"]=positional[3])
            action in ("rename","forget") && (args["expected_revision"]=revision)
            if action=="rename"
                haskey(flags,"--title") || throw(ShenScopeError(:input,"Use tests rename RUN_ID --title LABEL --expected-revision N"))
                args["label"]=flags["--title"]
            end
            println(canonical(execute(tool,args,ctx)));return 0
        end
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
        value=execute(tool,args,ctx)
        if save
            saved=try
                save_project_test_history!(project_test_history_store(ctx),tool.manager,value["run_id"],ctx;expected_revision=revision)
            catch cause
                cause isa InterruptException && rethrow()
                println(canonical(Dict("report"=>value,"saved"=>nothing,"save_error"=>
                    Dict("code"=>cause isa ShenScopeError ? String(cause.code) : "storage","message"=>sprint(showerror,cause)),"automatic_replay"=>false)))
                return 2
            end
            println(canonical(Dict("report"=>value,"saved"=>saved,"automatic_replay"=>false)))
        else
            println(canonical(value))
        end
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
