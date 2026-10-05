function cli_plan_command(positional,flags,config,state_dir)
    length(positional)>=2 && haskey(flags,"--session") || throw(ShenScopeError(:input,"Plan operations require an action and --session ID"))
    action=positional[2]
    action in ("get","history","replace","progress") || throw(ShenScopeError(:input,"Use plan get, history, replace or progress"))
    policy=permissions_from_config(config)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());session_id=flags["--session"],state_dir,permissions=policy,
        budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    session=load_session(state_dir,ctx.session_id);tool=PlanTool()
    bind_agent_plan_session!(tool.manager,session,ctx)
    arguments=Dict{String,Any}("action"=>action)
    if action in ("replace","progress")
        length(positional)==3 && haskey(flags,"--expected-revision") ||
            throw(ShenScopeError(:input,"Plan writes require a workspace JSON file and --expected-revision N"))
        path=workspace_path(ctx.root,positional[3];must_exist=true)
        authorize!(ctx,:read,"plan.input",path;reason="Read the explicitly selected plan input file")
        _,text=read_workspace_text(ctx,path;max_bytes=AGENT_PLAN_MAX_BYTES)
        value=bounded_json_object(text;maximum=AGENT_PLAN_MAX_BYTES,max_depth=16,max_nodes=8192,error_code=:arguments)
        agent_control_fields(value,action=="replace" ? ["title","steps"] : ["id","status","note","citations"],"plan input")
        merge!(arguments,value)
        revision=tryparse(Int,flags["--expected-revision"])
        revision===nothing && throw(ShenScopeError(:input,"Plan revision must be an integer"))
        arguments["expected_revision"]=revision
    else
        length(positional)==2 || throw(ShenScopeError(:input,"Plan reads do not accept positional data"))
        haskey(flags,"--expected-revision") && throw(ShenScopeError(:input,"Plan reads do not accept an expected revision"))
        action=="history" && haskey(flags,"--limit") && (arguments["limit"]=parse(Int,flags["--limit"]))
    end
    result=if action in ("replace","progress")
        with_session_run_fence(session,ctx) do
            session.status==:running && throw(ShenScopeError(:session_busy,"Finish the active run before editing its plan"))
            execute(tool,arguments,ctx)
        end
    else
        execute(tool,arguments,ctx)
    end
    println(canonical(result));0
end

function terminal_control_command!(state::TerminalState,prompt::AbstractString,session::Session,ctx::RuntimeContext)
    args=split(prompt)
    if first(args)=="/mode"
        length(args) in (1,2) || throw(ShenScopeError(:input,"Use /mode [plan|act]"))
        if length(args)==2
            state.active && !state.control_busy && throw(ShenScopeError(:session_busy,"Finish or cancel the active run before changing its mode"))
            set_agent_mode!(session,ctx,args[2];expected_revision=agent_mode_setting(session)["revision"])
        end
        setting=agent_mode_view(session)
        terminal_push!(state,"Agent mode: "*setting["mode"]*". Plan reads and reports intent; Act uses tools subject to permissions.")
    elseif first(args)=="/plan"
        length(args)==1 || throw(ShenScopeError(:input,"Use /plan to view the reported conversation plan"))
        value=read_agent_plan(session,ctx);plan=value["plan"]
        if plan===nothing
            terminal_push!(state,"No conversation plan saved yet.")
        else
            terminal_push!(state,"Plan: "*plan["title"]*" · revision "*string(plan["revision"])*" · reported progress")
            for step in plan["steps"]
                terminal_push!(state,"["*step["status"]*"] "*step["id"]*": "*step["text"])
            end
            terminal_push!(state,"Saved progress is not independent proof of completion.")
        end
    else
        throw(ShenScopeError(:input,"Unknown terminal control command"))
    end
    nothing
end
