function cli_terminal_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Terminal action is required"))
    action=positional[2]
    action=="platform" && (println(canonical(terminal_platform_view()));return 0)
    action=="run" || throw(ShenScopeError(:input,"CLI terminal supports platform and ephemeral run; use RPC for retained handles"))
    haskey(flags,"--argv") || throw(ShenScopeError(:input,"Terminal run requires --argv with a JSON argument array"))
    argv=parsejson(flags["--argv"])
    argv isa AbstractVector && !isempty(argv) && all(x->x isa String,argv) ||
        throw(ShenScopeError(:input,"Terminal argv must be a nonempty string array"))
    function integer_flag(name,default)
        haskey(flags,name) || return default
        try parse(Int,flags[name]) catch;throw(ShenScopeError(:input,"Invalid terminal integer flag: "*name));end
    end
    timeout=try parse(Float64,get(flags,"--timeout","120")) catch;throw(ShenScopeError(:input,"Invalid terminal timeout"));end
    policy=permissions_from_config(config);get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,
        sandbox=sandbox_from_config(config),approve=cli_approval,budget=BudgetLedger(limits_from_config(config)))
    manager=TerminalManager()
    try
        handle=terminal_start!(manager,String.(argv),ctx;timeout,
            size=TerminalSize(integer_flag("--rows",24),integer_flag("--columns",80)))
        terminal_wait_ready!(handle,ctx)
        haskey(flags,"--input") && terminal_write!(handle,flags["--input"],ctx)
        offset=0
        while handle.monitor!==nothing && !istaskdone(handle.monitor)
            if !get(flags,"--json",false)
                page=terminal_page(handle.journal;offset)
                page["lost_bytes"]>0 && println(stderr,"Terminal output retention lost ",page["lost_bytes"]," bytes")
                print(stdout,page["text"]);flush(stdout);offset=page["next_offset"]
            end
            sleep(0.025)
        end
        handle.monitor!==nothing && wait(handle.monitor)
        result=terminal_status(handle)
        page=terminal_page(handle.journal;offset=get(flags,"--json",false) ? 0 : offset)
        if get(flags,"--json",false)
            result["output"]=page;println(canonical(result))
        else
            print(stdout,page["text"]);flush(stdout)
        end
        result["exit_code"]===nothing ? 1 : result["exit_code"]==0 ? 0 : 1
    finally
        cleanup_terminals!(manager;close_manager=true)
    end
end
