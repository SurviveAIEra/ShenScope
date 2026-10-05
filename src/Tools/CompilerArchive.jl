const COMPILER_ARCHIVE_ACTIONS=["archive_save","archive_list","archive_get","archive_label",
    "archive_delete","archive_compare","archive_gc","archive_source"]

function diagnostics_arguments(args::AbstractDict)
    action=get(args,"action",nothing)
    allowed=if action in ("compile","compile_archive")
        fields=["target","mode","timeout","max_ir_bytes","max_statements"]
        action=="compile_archive" ? vcat(fields,["title","expected_revision"]) : fields
    elseif action in ("profile","inspect")
        fields=["target","fixture","timeout","iterations","repetitions","max_samples","max_frames","sample_rate"]
        action=="inspect" ? vcat(fields,["offset","limit","query","observation_kind"]) : fields
    elseif action in ("evidence","evidence_source")
        fields=["compiler_job_id","profile_job_id","expected_evidence_sha256"]
        vcat(fields,action=="evidence_source" ? ["observation_key","context_lines"] : ["offset","limit","query","observation_kind"])
    elseif action=="archive_save"
        ["job_id","expected_revision","title"]
    elseif action=="archive_list"
        ["offset","limit","target","expected_index_sha256"]
    elseif action=="archive_get"
        ["report_id","expected_index_sha256"]
    elseif action in ("compiler_source","archive_source")
        vcat(action=="compiler_source" ? ["job_id"] : ["report_id","expected_index_sha256"],
            ["method_index","statement_id","context_lines"])
    elseif action=="archive_label"
        ["report_id","title","expected_revision"]
    elseif action=="archive_delete"
        ["report_id","expected_revision"]
    elseif action=="archive_compare"
        ["before_id","after_id","limit","expected_index_sha256"]
    elseif action=="archive_gc"
        ["dry_run","expected_revision"]
    elseif action in ("contracts","ambiguities","targets")
        String[]
    else
        throw(ShenScopeError(:diagnostics,"Unknown diagnostics action"))
    end
    all(key->key=="action" || key in allowed,keys(args)) ||
        throw(ShenScopeError(:diagnostics,"Unexpected parameter for diagnostics action "*action))
    action in ("evidence","evidence_source") && !any(key->haskey(args,key),("compiler_job_id","profile_job_id")) &&
        throw(ShenScopeError(:diagnostics,"Select an owned compiler or runtime measurement job"))
    required=action=="evidence_source" ? ["observation_key","expected_evidence_sha256"] :
        action in ("compile","profile","inspect") ? ["target"] : action=="compile_archive" ? ["target","expected_revision"] :
        action=="archive_save" ? ["job_id","expected_revision"] :
        action in ("archive_get","archive_source") ? ["report_id"] : action=="compiler_source" ? ["job_id"] :
        action=="archive_label" ? ["report_id","title","expected_revision"] :
        action=="archive_delete" ? ["report_id","expected_revision"] : action=="archive_compare" ? ["before_id","after_id"] :
        action=="archive_gc" && !get(args,"dry_run",true) ? ["expected_revision"] : String[]
    all(key->haskey(args,key),required) || throw(ShenScopeError(:diagnostics,"Required diagnostics action parameter missing"))
    nothing
end

function diagnostics_compiler_source(tool,args::AbstractDict,ctx::RuntimeContext)
    view=owned_operation(tool.operations,args["job_id"],ctx)
    view["action"] in ("compile","compile_archive") && view["status"]=="complete" &&
        view["result"] isa AbstractDict && get(view["metadata"],"mode",nothing)=="graph" ||
        throw(ShenScopeError(:diagnostics,"Source preview requires an owned completed graph-inference job"))
    root=runtime_core_root()
    authorize!(ctx,:read,"runtime.diagnostics",root;
        reason="Verify the installed Core inventory and read a bounded compiler source excerpt")
    snapshot=runtime_source_snapshot(ctx;root,authorized=true)
    report=view["result"]["report"]
    compiler_ir_validate_report(report,compiler_target(report["target"]),snapshot;
        limits=compiler_archive_limits(report))
    compiler_source_excerpt(report,snapshot,ctx;method_index=get(args,"method_index",1),
        statement_id=get(args,"statement_id",0),context_lines=get(args,"context_lines",4),root,authorized=true)
end

function diagnostics_compile_archive(args::AbstractDict,ctx::RuntimeContext)
    compiler_target(args["target"])
    get(args,"mode","graph")=="graph" || throw(ShenScopeError(:diagnostics,"Compile-and-save requires graph mode"))
    expected=compiler_archive_revision(args["expected_revision"])
    title=compiler_ir_text(get(args,"title","Compiler report"),"archive title",512)
    store=compiler_archive_store(ctx)
    compiler_archive_checkpoint(store,ctx,:persistence)
    compiler_archive_authorize(store,ctx,:read)
    index=compiler_archive_read_index(store,ctx)
    index["revision"]==expected || throw(ShenScopeError(:conflict,"Compiler archive revision changed before inference"))
    result=run_compiler_diagnostic(ctx,args["target"];mode="graph",timeout=get(args,"timeout",60.0),
        max_ir_bytes=get(args,"max_ir_bytes",64*1024),max_statements=get(args,"max_statements",2048))
    saved=compiler_archive_save(store,result,ctx;expected_revision=expected,title)
    merge(result,Dict("archive"=>saved))
end

function diagnostics_archive_execute(tool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"];store=compiler_archive_store(ctx)
    if action=="archive_save"
        view=owned_operation(tool.operations,args["job_id"],ctx)
        view["action"]=="compile" && view["status"]=="complete" && view["result"] isa AbstractDict &&
            get(view["metadata"],"mode",nothing)=="graph" ||
            throw(ShenScopeError(:diagnostics,"Save requires an owned completed graph-inference job"))
        return compiler_archive_save(store,view["result"],ctx;
            expected_revision=args["expected_revision"],title=get(args,"title","Compiler report"))
    elseif action=="archive_list"
        return compiler_archive_list(store,ctx;offset=get(args,"offset",0),limit=get(args,"limit",20),
            target=get(args,"target",nothing),expected_index_sha256=get(args,"expected_index_sha256",nothing))
    elseif action=="archive_get"
        return compiler_archive_get(store,args["report_id"],ctx;expected_index_sha256=get(args,"expected_index_sha256",nothing))
    elseif action=="archive_source"
        return compiler_archive_source(store,args["report_id"],ctx;expected_index_sha256=get(args,"expected_index_sha256",nothing),
            method_index=get(args,"method_index",1),statement_id=get(args,"statement_id",0),
            context_lines=get(args,"context_lines",4))
    elseif action=="archive_label"
        return compiler_archive_label(store,args["report_id"],args["title"],ctx;expected_revision=args["expected_revision"])
    elseif action=="archive_delete"
        return compiler_archive_delete(store,args["report_id"],ctx;expected_revision=args["expected_revision"])
    elseif action=="archive_compare"
        return compiler_archive_compare(store,args["before_id"],args["after_id"],ctx;
            limit=get(args,"limit",128),expected_index_sha256=get(args,"expected_index_sha256",nothing))
    elseif action=="archive_gc"
        return compiler_archive_gc(store,ctx;dry_run=get(args,"dry_run",true),expected_revision=get(args,"expected_revision",nothing))
    end
    throw(ShenScopeError(:diagnostics,"Unknown compiler archive action"))
end
