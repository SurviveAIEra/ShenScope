function cli_memory_command(positional::Vector{String},flags::AbstractDict,config::AbstractDict,state_dir::String)
    length(positional)>=2 || throw(ShenScopeError(:input,"Use memory status, namespaces, list, retrieve, get, history, put, delete, export or import"))
    action=positional[2];args=Dict{String,Any}("action"=>action,"scope"=>get(flags,"--scope","workspace"),
        "namespace"=>get(flags,"--namespace",MEMORY_DEFAULT_NAMESPACE))
    policy=permissions_from_config(config)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-memory"),
        permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    if args["scope"]=="session"
        haskey(flags,"--session") || throw(ShenScopeError(:input,"Session memory requires --session"))
        session=load_session(state_dir,ctx.session_id)
        realpath(session.root)==ctx.root || throw(ShenScopeError(:permission,"Memory conversation belongs to another workspace"))
    end
    if action in ("get","history","delete")
        length(positional)==3 || throw(ShenScopeError(:input,"Memory key required"));args["key"]=positional[3]
    elseif action in ("retrieve","search")
        length(positional)>=3 || throw(ShenScopeError(:input,"Memory query required"));args["query"]=join(positional[3:end]," ")
    elseif action=="put"
        length(positional)==4 || throw(ShenScopeError(:input,"Use memory put KEY CONTENT_FILE --expected-version N"))
        args["key"]=positional[3]
        args["content"]=read_scoped_text(ctx,ctx.root,positional[4],65536;tool="memory.content",reason="Read memory content input")
        haskey(flags,"--title") && (args["title"]=flags["--title"])
        haskey(flags,"--tags") && (args["tags"]=filter(!isempty,strip.(split(flags["--tags"],','))))
    elseif action=="import"
        length(positional)==3 || throw(ShenScopeError(:input,"Memory import file required"))
        args["document"]=bounded_json_object(read_scoped_text(ctx,ctx.root,positional[3],MAX_MEMORY_PREVIEW_BYTES;
            tool="memory.import_source",reason="Read memory import input");maximum=MAX_MEMORY_PREVIEW_BYTES)
    else
        length(positional)==2 || throw(ShenScopeError(:input,"Unexpected memory argument"))
    end
    for (flag,key) in (("--limit","limit"),("--offset","offset"),("--expected-version","expected_version"),
            ("--snippet-chars","snippet_chars"))
        haskey(flags,flag) || continue
        value=tryparse(Int,flags[flag]);value===nothing && throw(ShenScopeError(:input,flag*" must be an integer"))
        args[key]=value
    end
    for (flag,key) in (("--match","match"),("--sort","sort"),("--cursor","cursor"),("--expected-snapshot","expected_snapshot"))
        haskey(flags,flag) && (args[key]=flags[flag])
    end
    for (flag,key) in (("--tags-all","tags_all"),("--tags-any","tags_any"),("--sources","sources"))
        haskey(flags,flag) && (args[key]=filter(!isempty,strip.(split(flags[flag],','))))
    end
    tool=MemoryTool()
    try
        validate_schema(args,tool_schema(tool));println(canonical(execute(tool,args,ctx;user_requested=true)))
        0
    finally
        cleanup_memory!(tool.manager)
    end
end
