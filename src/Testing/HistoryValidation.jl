function project_test_history_report(value,store::ProjectTestHistoryStore,ctx::RuntimeContext)
    value isa AbstractDict || throw(ShenScopeError(:testing,"Saved test receipt must be an object"))
    required=["schema","run_id","created_at","finished_at","session_id","root_sha256","catalog_id","command","process","parsed",
        "exit_code","timed_out","cancelled","permission_revoked","outcome","execution_source_snapshot_verified","automatic_replay","limitations","sha256"]
    Set(keys(value)) in (Set(required),Set(vcat(required,["receipt_trimmed_for_transport"]))) ||
        throw(ShenScopeError(:testing,"Invalid saved test receipt fields"))
    value["schema"]==PROJECT_TEST_REPORT_SCHEMA && value["session_id"]==store.session_id && value["root_sha256"]==store.workspace_sha256 ||
        throw(ShenScopeError(:permission,"Saved test receipt has a foreign schema or owner"))
    valid_id(project_test_text(value["run_id"],"saved test run ID",128))
    project_test_history_timestamp(value["created_at"]);project_test_history_timestamp(value["finished_at"])
    value["catalog_id"]===nothing || project_test_history_hash(value["catalog_id"],"saved catalog digest")
    value["automatic_replay"]===false && value["execution_source_snapshot_verified"]===false ||
        throw(ShenScopeError(:testing,"Saved test receipt claims unsupported replay or source certification"))
    for field in ("timed_out","cancelled","permission_revoked")
        value[field] isa Bool || throw(ShenScopeError(:testing,"Invalid saved test execution flags"))
    end
    value["outcome"] in ("command_succeeded","command_failed","reported_failure","timed_out","permission_revoked","cancelled","signalled") ||
        throw(ShenScopeError(:testing,"Invalid saved test outcome"))
    command=value["command"];parsed=value["parsed"];process=value["process"]
    command isa AbstractDict && parsed isa AbstractDict && process isa AbstractDict || throw(ShenScopeError(:testing,"Invalid saved test evidence"))
    project_test_text(get(command,"label",nothing),"saved command label",512)
    project_test_history_hash(get(command,"id",nothing),"saved command identity")
    digest(canonical(Dict(key=>item for (key,item) in command if key!="id")))==command["id"] ||
        throw(ShenScopeError(:conflict,"Saved command identity does not match its content"))
    argv=get(command,"argv",nothing)
    argv isa AbstractVector && 1<=length(argv)<=128 && all(item->item isa String && isvalid(item) && !occursin('\0',item) && ncodeunits(item)<=8192,argv) ||
        throw(ShenScopeError(:testing,"Invalid saved test command arguments"))
    get(parsed,"framework",nothing) in PROJECT_TEST_FRAMEWORKS && parsed["framework"]==get(command,"framework",nothing) ||
        throw(ShenScopeError(:testing,"Invalid saved test output format"))
    get(parsed,"case_results_independently_verified",nothing)===false && get(parsed,"complete_project_coverage",nothing)===false ||
        throw(ShenScopeError(:testing,"Saved test output claims unsupported correctness or coverage"))
    cases=get(parsed,"cases",nothing);frames=get(parsed,"frames",nothing)
    cases isa AbstractVector && length(cases)<=PROJECT_TEST_MAX_CASES && frames isa AbstractVector && length(frames)<=PROJECT_TEST_MAX_FRAMES ||
        throw(ShenScopeError(:capacity,"Saved test interpretation exceeds its entry limit"))
    for item in cases
        item isa AbstractDict && get(item,"status",nothing) in PROJECT_TEST_CASE_STATUSES && get(item,"source",nothing)=="framework_reported" ||
            throw(ShenScopeError(:testing,"Invalid saved framework case"))
        project_test_history_hash(get(item,"id",nothing),"saved case identity")
        project_test_text(get(item,"name",nothing),"saved case name",2048;empty=true)
        project_test_text(get(item,"suite",nothing),"saved case suite",1024;empty=true)
    end
    frame_ids=String[]
    for frame in frames
        frame isa AbstractDict || throw(ShenScopeError(:testing,"Invalid saved source reference"))
        id=project_test_history_hash(get(frame,"id",nothing),"saved source reference identity")
        body=Dict(key=>item for (key,item) in frame if key!="id")
        digest(canonical(body))==id || throw(ShenScopeError(:conflict,"Saved source reference identity changed"))
        path=project_test_text(get(frame,"path",nothing),"saved source reference path",4096)
        location=project_test_output_location(ctx,ctx.root,path,string(get(frame,"line",nothing)),
            get(frame,"column",nothing)===nothing ? nothing : string(frame["column"]))
        location!==nothing && location["path"]==path && get(frame,"source",nothing)=="captured_output" &&
            get(frame,"source_snapshot_verified",nothing)===false && get(frame,"file_existence_checked",nothing)===false ||
            throw(ShenScopeError(:permission,"Saved test source reference is unsafe or claims unsupported certification"))
        push!(frame_ids,id)
    end
    length(unique(frame_ids))==length(frame_ids) || throw(ShenScopeError(:testing,"Saved source references are duplicated"))
    get(process,"exit_code",nothing)==value["exit_code"] && get(process,"timed_out",nothing)==value["timed_out"] &&
        get(process,"permission_revoked",nothing)==value["permission_revoked"] || throw(ShenScopeError(:testing,"Saved process outcome fields disagree"))
    for field in ("stdout","stderr")
        text=get(process,field,nothing)
        text isa String && isvalid(text) && ncodeunits(text)<=store.limits.report_bytes ||
            throw(ShenScopeError(:testing,"Invalid saved process output"))
    end
    project_test_history_hash(value["sha256"],"saved report digest")
    body=project_test_report_body(value)
    raw=bounded_canonical_json(body;maximum=store.limits.report_bytes,max_depth=20,max_nodes=100_000)
    digest(raw)==value["sha256"] || throw(ShenScopeError(:conflict,"Saved test receipt digest changed"))
    ncodeunits(bounded_canonical_json(value;maximum=store.limits.report_bytes,max_depth=20,max_nodes=100_000))
end

function project_test_history_validate(value,store::ProjectTestHistoryStore,ctx::RuntimeContext)
    project_test_fields(value,["schema","owner","revision","entries","sha256"],"saved test history")
    value["schema"]==PROJECT_TEST_HISTORY_SCHEMA && value["owner"]==project_test_history_owner(store) ||
        throw(ShenScopeError(:permission,"Saved test history has a foreign schema or owner"))
    project_test_history_revision(value["revision"])
    entries=value["entries"]
    entries isa AbstractVector && length(entries)<=store.limits.reports || throw(ShenScopeError(:capacity,"Saved test report limit reached"))
    ids=String[]
    for entry in entries
        project_test_fields(entry,["run_id","label","saved_at","report_bytes","report"],"saved test entry")
        id=valid_id(project_test_text(entry["run_id"],"saved test run ID",128));push!(ids,id)
        project_test_text(entry["label"],"saved result label",512);project_test_history_timestamp(entry["saved_at"])
        bytes=project_test_integer(entry["report_bytes"],"saved receipt bytes",1,store.limits.report_bytes)
        project_test_history_report(entry["report"],store,ctx)==bytes && entry["report"]["run_id"]==id ||
            throw(ShenScopeError(:testing,"Saved receipt identity or byte count disagrees with its entry"))
    end
    issorted(ids) && length(unique(ids))==length(ids) || throw(ShenScopeError(:testing,"Saved test IDs must be sorted and unique"))
    hash=project_test_history_hash(value["sha256"],"saved history digest")
    body=Dict(key=>item for (key,item) in value if key!="sha256")
    digest(bounded_canonical_json(body;maximum=store.limits.snapshot_bytes,max_depth=24,max_nodes=1_000_000))==hash ||
        throw(ShenScopeError(:conflict,"Saved test history digest changed"))
    value
end
