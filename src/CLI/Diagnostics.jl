function cli_diagnostics_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Diagnostics action required"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-dynamic",false) && (policy.rules[:dynamic]=Allow)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    action=positional[2];save=get(flags,"--save",false)
    archival=action in COMPILER_ARCHIVE_ACTIONS || action=="compile_archive" || save
    archival && !haskey(flags,"--session") && throw(ShenScopeError(:input,"Compiler report archives require --session ID"))
    save && (action!="compile" || get(flags,"--mode","graph")!="graph" || !haskey(flags,"--expected-revision")) &&
        throw(ShenScopeError(:input,"Saving inference requires compile --mode graph --expected-revision N"))
    ctx=RuntimeContext(get(flags,"--root",pwd());session_id=get(flags,"--session","cli-diagnostics"),
        state_dir,permissions=policy,sandbox=sandbox_from_config(config),
        budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    if archival
        session=load_session(state_dir,ctx.session_id)
        realpath(session.root)==ctx.root || throw(ShenScopeError(:permission,"Compiler archive conversation belongs to another workspace"))
    end
    action=="archive_save" && throw(ShenScopeError(:input,"CLI inference can be archived with compile TARGET --mode graph --save"))
    action=="compiler_source" && throw(ShenScopeError(:input,"CLI previews use archive_source REPORT_ID --session ID"))
    action in ("evidence","evidence_source") && throw(ShenScopeError(:input,"CLI source association uses inspect TARGET; owned job queries use RPC"))
    args=Dict{String,Any}("action"=>save ? "compile_archive" : action)
    if action in ("compile","compile_archive","profile","inspect")
        length(positional)==3 || throw(ShenScopeError(:input,"Compiler target required"));args["target"]=positional[3]
        save && (args["mode"]="graph")
    elseif action in ("archive_get","archive_label","archive_delete","archive_source")
        length(positional)==3 || throw(ShenScopeError(:input,"Archive report digest required"));args["report_id"]=positional[3]
    elseif action=="archive_compare"
        length(positional)==4 || throw(ShenScopeError(:input,"Two archive report digests required"))
        args["before_id"]=positional[3];args["after_id"]=positional[4]
    else
        length(positional)==2 || throw(ShenScopeError(:input,"Unexpected diagnostics argument"))
    end
    haskey(flags,"--mode") && (args["mode"]=flags["--mode"])
    haskey(flags,"--timeout") && (args["timeout"]=parse(Float64,flags["--timeout"]))
    for (flag,key) in (("--max-ir-bytes","max_ir_bytes"),("--max-statements","max_statements"),
            ("--limit","limit"),("--offset","offset"),("--expected-revision","expected_revision"),
            ("--method-index","method_index"),("--statement-id","statement_id"),("--context-lines","context_lines"),
            ("--iterations","iterations"),("--repetitions","repetitions"),("--max-samples","max_samples"),("--max-frames","max_frames"))
        haskey(flags,flag) || continue
        value=tryparse(Int,flags[flag]);value===nothing && throw(ShenScopeError(:input,flag*" must be an integer"))
        args[key]=value
    end
    haskey(flags,"--title") && (args["title"]=flags["--title"])
    haskey(flags,"--fixture") && (args["fixture"]=flags["--fixture"])
    haskey(flags,"--query") && (args["query"]=flags["--query"])
    haskey(flags,"--observation-kind") && (args["observation_kind"]=flags["--observation-kind"])
    if haskey(flags,"--sample-rate")
        rate=tryparse(Float64,flags["--sample-rate"]);rate===nothing && throw(ShenScopeError(:input,"--sample-rate must be a number"))
        args["sample_rate"]=rate
    end
    haskey(flags,"--expected-index-sha256") && (args["expected_index_sha256"]=flags["--expected-index-sha256"])
    get(flags,"--apply-cleanup",false) && (args["dry_run"]=false)
    tool=DiagnosticsTool();validate_schema(args,tool_schema(tool));diagnostics_arguments(args)
    result=execute(tool,args,ctx)
    println(canonical(result));return 0
end
