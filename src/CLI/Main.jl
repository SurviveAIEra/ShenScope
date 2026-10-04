function cli_approval(request::PermissionRequest)
    if !(stdin isa Base.TTY)
        return :deny
    end
    println(stderr,"Permission: ",request.category," / ",request.tool,"\n",request.target)
    print(stderr,"Allow once [a], allow session [s], deny [d]: ")
    flush(stderr)
    answer=lowercase(strip(readline(stdin)))
    return answer=="a" ? :once : answer=="s" ? :session : :deny
end

function render_event(io::IO,event::AgentEvent;json=false)
    if json
        println(io,canonical(Dict("sequence"=>event.sequence,"kind"=>String(event.kind),
            "session_id"=>event.session_id,"trace_id"=>event.trace_id,
            "timestamp"=>event.timestamp,"payload"=>event.payload)))
    elseif event.kind==:text_delta
        print(io,event.payload["text"])
    elseif event.kind==:tool_started
        println(stderr,"\n[",event.payload["name"],"]")
    elseif event.kind==:session_completed
        println(io)
    elseif event.kind==:no_progress
        println(stderr,"Repeated tool results; no new evidence observed.")
    elseif event.kind==:context_compacted
        println(stderr,"Context checkpoint saved; original messages remain available.")
    elseif event.kind==:context_recovery
        println(stderr,"Reducing context after model input limit.")
    end
    flush(io)
end

function parse_cli(args::Vector{String})
    flags=Dict{String,Any}();positionals=String[]
    valued=Set(["--root","--state-dir","--config","--profile","--session","--script","--backend",
        "--symbol","--column-unit","--limit","--offset","--revision","--sha256","--minimum-savings",
        "--poll-seconds","--quiet-seconds","--duration","--watch-file-limit","--watch-byte-limit",
        "--scope","--expected-pointer"])
    switches=Set(["--json","--stdio","--allow-edit","--allow-process","--allow-network","--allow-persistence","--allow-dynamic","--allow-mcp","--exclude-declarations","--force","--automatic","--no-native-hints"])
    i=1
    while i<=length(args)
        arg=args[i]
        if arg in valued
            i<length(args) || throw(ShenScopeError(:input,arg * " requires a value"))
            flags[arg]=args[i+1];i+=2
        elseif arg in switches
            flags[arg]=true;i+=1
        elseif startswith(arg,"--")
            throw(ShenScopeError(:input,"Unknown option " * arg))
        else
            push!(positionals,arg);i+=1
        end
    end
    return positionals,flags
end

function scripted_provider(path::String)
    filesize(path)<=8*1024*1024 || throw(ShenScopeError(:input,"Mock script exceeds limit"))
    doc=parsejson(read(path,String))
    doc isa AbstractVector || throw(ShenScopeError(:input,"Mock script must be an array"))
    script=Any[]
    for step in doc
        calls=ToolCall[ToolCall(get(c,"id",string(uuid4())),c["name"],Dict{String,Any}(c["arguments"]))
            for c in get(step,"calls",[])]
        push!(script,response(get(step,"text","");calls))
    end
    return MockProvider(script)
end

function cli_session_command(args::Vector{String},state_dir::String)
    isempty(args) && throw(ShenScopeError(:input,"Expected sessions list, export, rename or archive"))
    action=first(args)
    if action=="list"
        println(canonical(list_sessions(state_dir;include_archived=true)))
        return 0
    end
    length(args)>=2 || throw(ShenScopeError(:input,"Session ID required"))
    s=load_session(state_dir,args[2])
    if action=="export"
        println(canonical(Dict("id"=>s.id,"root"=>s.root,"title"=>s.title,
            "messages"=>message_dict.(s.messages),"metadata"=>s.metadata)))
    elseif action=="rename"
        length(args)>=3 || throw(ShenScopeError(:input,"Session title required"))
        rename_session!(s,join(args[3:end]," "))
    elseif action=="archive"
        session_record!(s,"metadata",Dict("archived"=>true))
    else
        throw(ShenScopeError(:input,"Unknown sessions command"))
    end
    return 0
end

function cli_main(args=ARGS)
    if args==["--version"]
        println("ShenScope ",VERSION);return 0
    end
    if isempty(args) || args==["--help"]
        println("ShenScope — Open coding intelligence for serious codebases.")
        println("Usage: shenscope chat TASK | tui | sessions ACTION | project ACTION | tasks ACTION | mcp ACTION | skills ACTION | hooks ACTION | context ACTION | analyzers ACTION | diagnostics ACTION | doctor | serve --stdio")
        println("Options: --root PATH --state-dir PATH --config PATH --profile NAME --session ID --json")
        println("Explicit permissions: --allow-edit --allow-process --allow-network --allow-persistence --allow-dynamic --allow-mcp")
        println("Offline protocol fixture: --script JSON_FILE")
        println("Project navigation: project definitions|references|hover|incoming_calls|outgoing_calls|implementations FILE LINE COLUMN --backend typescript")
        println("Project evidence: --symbol ID --column-unit utf8_byte|utf16 --revision N --sha256 HASH --limit N --offset N --exclude-declarations; project diagnostics [FILE]")
        println("Project cache: project compact --backend NAME --minimum-savings BYTES [--force]")
        println("Project changes: project watch --backend NAME [--automatic] [--poll-seconds N] [--duration N]")
        return 0
    end
    try
        positional,flags=parse_cli(String.(args))
        isempty(positional) && throw(ShenScopeError(:input,"Command required"))
        command=first(positional)
        state_dir=get(flags,"--state-dir",get(ENV,"SHENSCOPE_STATE_DIR",joinpath(homedir(),".local/state/shenscope")))
        if command=="sessions"
            return cli_session_command(positional[2:end],state_dir)
        end
        config=load_config(;path=get(flags,"--config",config_path()),profile=get(flags,"--profile",nothing))
        command=="mcp" && return cli_mcp_command(positional,flags,config,state_dir)
        command=="skills" && return cli_skills_command(positional,flags,config,state_dir)
        command=="hooks" && return cli_hooks_command(positional,flags,config,state_dir)
        command=="context" && return cli_context_command(positional,flags,config,state_dir)
        command=="analyzers" && return cli_analyzers_command(positional,flags,config,state_dir)
        if command=="tasks"
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
            factory=haskey(flags,"--script") ? ctx->scripted_provider(flags["--script"]) : ctx->provider_from_config(config)
            tool=TaskTool(WorkExecutor(;tools=core_tools(;tasks=false,config),provider_factory=factory))
            try
                validate_schema(args,tool_schema(tool));println(canonical(execute(tool,args,ctx)))
            finally
                cleanup_tasks!(tool.manager)
            end
            return 0
        end
        if command=="diagnostics"
            length(positional)>=2 || throw(ShenScopeError(:input,"Diagnostics action required"))
            policy=permissions_from_config(config)
            get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
            get(flags,"--allow-dynamic",false) && (policy.rules[:dynamic]=Allow)
            ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,approve=cli_approval)
            args=Dict{String,Any}("action"=>positional[2])
            length(positional)>=3 && (args["target"]=positional[3])
            tool=DiagnosticsTool();validate_schema(args,tool_schema(tool));println(canonical(execute(tool,args,ctx)));return 0
        end
        if command=="project"
            return cli_project_command(positional,flags,config,state_dir)
        end
        if command=="serve"
            get(flags,"--stdio",false) || throw(ShenScopeError(:input,"Use serve --stdio"))
            factory=haskey(flags,"--script") ? s->scripted_provider(flags["--script"]) : nothing
            return serve_stdio(CoreServer(get(flags,"--root",pwd());state_dir,
                config_file=get(flags,"--config",config_path()),provider_factory=factory))
        end
        if command=="doctor"
            p=provider_from_config(config)
            println(canonical(Dict("version"=>string(VERSION),"julia"=>string(Base.VERSION),
                "provider"=>provider_name(p),"protocol"=>String(p.config.protocol),"model"=>p.config.model,
                "key_configured"=>!isempty(get(ENV,p.config.key_env,"")),"key_variable"=>p.config.key_env,
                "state_dir"=>abspath(state_dir),"config_path"=>get(flags,"--config",config_path()),
                "sandbox"=>"host process; OS isolation not configured")))
            return 0
        end
        command in ("chat","tui") || throw(ShenScopeError(:input,"Unknown command"))
        root=get(flags,"--root",pwd())
        policy=permissions_from_config(config)
        for (flag,category) in (("--allow-edit",:edit),("--allow-process",:process),("--allow-network",:network),("--allow-persistence",:persistence),("--allow-dynamic",:dynamic),("--allow-mcp",:mcp))
            get(flags,flag,false) && (policy.rules[category]=Allow)
        end
        provider=haskey(flags,"--script") ? scripted_provider(flags["--script"]) : provider_from_config(config)
        if provider isa HTTPProvider && isempty(get(ENV,provider.config.key_env,"")) && provider.config.protocol!=:ollama
            throw(ShenScopeError(:credentials,"Configure " * provider.config.key_env * " securely before using a live model"))
        end
        id=get(flags,"--session",string(uuid4()))
        ctx=RuntimeContext(root;session_id=id,state_dir,budget=BudgetLedger(limits_from_config(config)),
            permissions=policy,approve=cli_approval,sink=e->render_event(stdout,e;json=get(flags,"--json",false)))
        session=haskey(flags,"--session") ? load_session(state_dir,id) : new_session(ctx)
        tools=core_tools(;config,config_source=get(flags,"--config",config_path()))
        if command=="chat"
            length(positional)>=2 || throw(ShenScopeError(:input,"Task text required"))
            try
                run_agent!(provider,join(positional[2:end]," "),ctx;session,tools)
            finally
                for tool in tools
                    tool isa MCPControlTool && cleanup_mcp!(tool.manager)
                    tool isa SkillsTool && cleanup_skills!(tool.manager)
                    tool isa HooksTool && cleanup_hooks!(tool.manager)
                    tool isa ContextTool && cleanup_context!(tool.manager)
                    tool isa AnalyzersTool && cleanup_analyzers!(tool.manager)
                    tool isa ProcessTool && cleanup_processes!(tool.manager,id)
                    tool isa TaskTool && cleanup_tasks!(tool.manager)
                end
            end
            println(stderr,"Session: ",session.id)
        else
            return run_tui(provider,ctx,session;tools)
        end
        return 0
    catch e
        if e isa InterruptException
            println(stderr,"Interrupted");return 130
        end
        println(stderr,e isa ShenScopeError ? sprint(showerror,e) : "Unexpected command failure: " * string(nameof(typeof(e))))
        return 1
    end
end
