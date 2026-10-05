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
        "--symbol","--file","--column-unit","--limit","--offset","--revision","--sha256","--minimum-savings",
        "--poll-seconds","--quiet-seconds","--duration","--watch-file-limit","--watch-byte-limit",
        "--scope","--expected-pointer","--count-mode","--model-role","--model-profile",
        "--history-limit","--bulk-threshold","--minimum-support","--change-kind","--order",
        "--max-depth","--max-files","--max-symbols","--max-relations","--minimum-confidence","--max-pairs",
        "--namespace","--title","--tags","--expected-version","--match","--sort","--cursor",
        "--expected-snapshot","--snippet-chars","--tags-all","--tags-any","--sources",
        "--backends","--evidence-key","--evidence-fingerprint","--scope-paths",
        "--package-name","--package-uuid","--package-version","--entry-sha256","--project-sha256","--contribution","--generation","--arguments",
        "--argv","--input","--rows","--columns","--timeout","--mode","--max-ir-bytes","--max-statements",
        "--expected-revision","--expected-index-sha256","--method-index","--statement-id","--context-lines",
        "--fixture","--iterations","--repetitions","--max-samples","--max-frames","--sample-rate","--sample-delay","--profile-buffer-words","--observation-kind","--query","--agent-mode","--framework","--cwd","--output-limit"])
    switches=Set(["--json","--stdio","--allow-edit","--allow-process","--allow-network","--allow-persistence","--allow-dynamic","--allow-mcp","--exclude-declarations","--force","--automatic","--no-native-hints","--no-evidence-bridges","--accept-cleanup-failure","--save","--apply-cleanup"])
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

function cli_session_command(args::Vector{String},state_dir::String;flags=Dict())
    isempty(args) && throw(ShenScopeError(:input,"Expected sessions list, export, rename, archive or mode"))
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
    elseif action=="mode"
        length(args) in (2,3) || throw(ShenScopeError(:input,"Usage: sessions mode ID [plan|act] --expected-revision N"))
        root=get(flags,"--root",s.root);ctx=RuntimeContext(root;session_id=s.id,state_dir)
        session_control_scope(s,ctx)
        if length(args)==2
            haskey(flags,"--expected-revision") && throw(ShenScopeError(:input,"Mode query does not accept an expected revision"))
            println(canonical(agent_mode_view(s)))
        else
            haskey(flags,"--expected-revision") || throw(ShenScopeError(:input,"Mode changes require --expected-revision"))
            println(canonical(set_agent_mode!(s,ctx,args[3];expected_revision=parse(Int,flags["--expected-revision"]))))
        end
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
        println("Usage: shenscope chat TASK | tui | sessions ACTION | project ACTION | tasks ACTION | mcp ACTION | skills ACTION | hooks ACTION | context ACTION | memory ACTION | analyzers ACTION | models ACTION | diagnostics ACTION | doctor | serve --stdio")
        println("Options: --root PATH --state-dir PATH --config PATH --profile NAME --session ID --json")
        println("Chat mode: --agent-mode plan|act; sessions mode ID [plan|act] --expected-revision N")
        println("Conversation plan: plan get|history --session ID; plan replace|progress JSON_FILE --session ID --expected-revision N")
        println("Project tests: tests discover [--scope-paths DIR,DIR]; tests run CANDIDATE_ID; tests custom --argv JSON [--framework unittest|pytest|tap|go_json|ctest|raw] [--allow-process]")
        println("Saved tests: run/custom --save --expected-revision N [--allow-persistence]; tests saved | show RUN_ID | rename RUN_ID --title LABEL | forget RUN_ID; writes require --expected-revision N. Use the same --root, --state-dir and --session across restarts.")
        println("Explicit permissions: --allow-edit --allow-process --allow-network --allow-persistence --allow-dynamic --allow-mcp")
        println("Offline protocol fixture: --script JSON_FILE")
        println("Project navigation: project definitions|references|hover|incoming_calls|outgoing_calls|implementations FILE LINE COLUMN --backend typescript")
        println("Project evidence: --symbol ID --column-unit utf8_byte|utf16 --revision N --sha256 HASH --limit N --offset N --exclude-declarations; project diagnostics [FILE]")
        println("Project cache: project compact --backend NAME --minimum-savings BYTES [--force]")
        println("Project history: project git_cochange|risk [FILE ...] --history-limit N --bulk-threshold N --minimum-support N --limit N")
        println("Julia source: project julia_methods|julia_dispatch|julia_structure [FILTER] --backend julia_syntax --max-pairs N")
        println("Combined evidence: project evidence_compare|evidence_search|evidence_impact|evidence_tests [FILE or QUERY] --backends NAME,NAME")
        println("Julia extensions: extensions list | inspect_package PACKAGE --package-uuid UUID; pinned ephemeral invoke uses --package-name, --package-version, --entry-sha256, --project-sha256 and --contribution")
        println("PTY terminal: terminal platform | terminal run --argv '[\"python3\",\"script.py\"]' [--input TEXT] [--rows 24 --columns 80] [--timeout 120] [--json]")
        println("Runtime image: runtime-image loaded | source | inspect RECEIPT | verify RECEIPT | plan RECEIPT")
        println("Core diagnostics: diagnostics profile|inspect TARGET; diagnostics sample TARGET [--duration 0.1 --sample-delay 0.001 --profile-buffer-words 20000]")
        println("Project migration: project migration FILE ... --change-kind signature|rename|remove|move|behavior --order dependency_first|callers_first --max-depth N")
        println("Project changes: project watch --backend NAME [--automatic] [--poll-seconds N] [--duration N]")
        println("Memory: memory retrieve QUERY --namespace NAME --scope workspace|session|user --tags-all TAGS --match any|all")
        println("Memory write: memory put KEY CONTENT_FILE --expected-version N [--allow-persistence]")
        println("Security: security status | security probe [--allow-process]")
        return 0
    end
    try
        positional,flags=parse_cli(String.(args))
        isempty(positional) && throw(ShenScopeError(:input,"Command required"))
        command=first(positional)
        state_dir=get(flags,"--state-dir",get(ENV,"SHENSCOPE_STATE_DIR",joinpath(homedir(),".local/state/shenscope")))
        if command=="sessions"
            return Base.invokelatest(cli_session_command,positional[2:end],state_dir;flags)
        end
        config=load_config(;path=get(flags,"--config",config_path()),profile=get(flags,"--profile",nothing))
        handler=get(CLI_COMMAND_HANDLERS,command,nothing)
        handler===nothing && throw(ShenScopeError(:input,"Unknown command"))
        # Keep unrelated commands outside this entry point's inference graph.
        return Base.invokelatest(handler,positional,flags,config,state_dir)
    catch e
        if e isa InterruptException
            println(stderr,"Interrupted");return 130
        end
        println(stderr,e isa ShenScopeError ? sprint(showerror,e) : "Unexpected command failure: " * string(nameof(typeof(e))))
        return 1
    end
end
