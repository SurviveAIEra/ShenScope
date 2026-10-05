const COMPILER_ARCHIVE_ACTIONS=["archive_save","archive_list","archive_get","archive_label",
    "archive_delete","archive_compare","archive_gc"]

function diagnostics_arguments(args::AbstractDict)
    action=get(args,"action",nothing)
    allowed=if action=="compile"
        ["target","mode","timeout","max_ir_bytes","max_statements"]
    elseif action=="archive_save"
        ["job_id","expected_revision","title"]
    elseif action=="archive_list"
        ["offset","limit","target","expected_index_sha256"]
    elseif action=="archive_get"
        ["report_id","expected_index_sha256"]
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
    required=action=="compile" ? ["target"] : action=="archive_save" ? ["job_id","expected_revision"] :
        action=="archive_get" ? ["report_id"] : action=="archive_label" ? ["report_id","title","expected_revision"] :
        action=="archive_delete" ? ["report_id","expected_revision"] : action=="archive_compare" ? ["before_id","after_id"] :
        action=="archive_gc" && !get(args,"dry_run",true) ? ["expected_revision"] : String[]
    all(key->haskey(args,key),required) || throw(ShenScopeError(:diagnostics,"Required diagnostics action parameter missing"))
    nothing
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
