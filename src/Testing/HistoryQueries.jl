function project_test_history_entry(value,id)
    key=valid_id(project_test_text(id,"saved test run ID",128))
    position=findfirst(entry->entry["run_id"]==key,value["entries"])
    position===nothing && throw(ShenScopeError(:testing,"Test run is absent from this conversation's saved history"))
    value["entries"][position]
end
function project_test_history_metadata(value,store::ProjectTestHistoryStore)
    Dict("revision"=>value["revision"],"history_sha256"=>value["sha256"],"owner"=>project_test_history_owner(store),
        "total"=>length(value["entries"]),"limits"=>Dict("reports"=>store.limits.reports,"report_bytes"=>store.limits.report_bytes,
            "snapshot_bytes"=>store.limits.snapshot_bytes),"survives_server_restart"=>true,"automatic_replay"=>false,
        "attestation"=>"Locally saved Core observations; digests detect content changes and do not authenticate external filesystem edits.")
end
function project_test_history_summary(entry)
    report=entry["report"]
    Dict("run_id"=>entry["run_id"],"label"=>entry["label"],"saved_at"=>entry["saved_at"],"report_bytes"=>entry["report_bytes"],
        "sha256"=>report["sha256"],"created_at"=>report["created_at"],"outcome"=>report["outcome"],"exit_code"=>report["exit_code"],
        "framework"=>report["parsed"]["framework"],"cases_observed"=>length(report["parsed"]["cases"]))
end
function list_project_test_history(store::ProjectTestHistoryStore,ctx::RuntimeContext;offset=0,limit=16,expected_history_sha256=nothing)
    first=project_test_integer(offset,"saved tests offset",0,32);bound=project_test_integer(limit,"saved tests page limit",1,32)
    expected_history_sha256===nothing || project_test_history_hash(expected_history_sha256,"expected saved history digest")
    project_test_history_authorize(store,ctx,:read);value=project_test_history_read(store,ctx)
    expected_history_sha256===nothing || value["sha256"]==expected_history_sha256 ||
        throw(ShenScopeError(:conflict,"Saved test history changed; restart pagination"))
    ordered=sort!(collect(value["entries"]);by=entry->(entry["saved_at"],entry["run_id"]),rev=true)
    last=min(length(ordered),first+bound);page=first<length(ordered) ? ordered[first+1:last] : Any[]
    result=merge(project_test_history_metadata(value,store),Dict("items"=>project_test_history_summary.(page),
        "next_offset"=>last<length(ordered) ? last : nothing,"order"=>"saved time descending, run ID descending"))
    project_test_history_checkpoint(store,ctx,:read);result
end
function read_project_test_history(store::ProjectTestHistoryStore,run_id,ctx::RuntimeContext;expected_history_sha256=nothing)
    expected_history_sha256===nothing || project_test_history_hash(expected_history_sha256,"expected saved history digest")
    project_test_history_authorize(store,ctx,:read);value=project_test_history_read(store,ctx)
    expected_history_sha256===nothing || value["sha256"]==expected_history_sha256 || throw(ShenScopeError(:conflict,"Saved test history changed"))
    entry=project_test_history_entry(value,run_id)
    result=merge(project_test_history_metadata(value,store),Dict("entry"=>project_test_history_summary(entry),"report"=>deepcopy(entry["report"])))
    project_test_history_checkpoint(store,ctx,:read);result
end
function read_saved_project_test_source(store::ProjectTestHistoryStore,run_id,frame_id,ctx::RuntimeContext;kwargs...)
    value=read_project_test_history(store,run_id,ctx)
    source=project_test_report_source(value["report"],frame_id,ctx;kwargs...)
    source["saved_history_sha256"]=value["history_sha256"];source["saved_history_revision"]=value["revision"]
    project_test_history_checkpoint(store,ctx,:read);source
end
