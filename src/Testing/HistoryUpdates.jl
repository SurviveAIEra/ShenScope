function project_test_history_transaction(f::Function,store::ProjectTestHistoryStore,ctx::RuntimeContext,expected_revision)
    revision=project_test_history_revision(expected_revision)
    project_test_history_authorize(store,ctx,:persistence)
    checkpoint=()->begin
        project_test_history_checkpoint(store,ctx,:persistence);project_test_history_guard(store,ctx)
    end
    store_lock(project_test_history_path(store);checkpoint) do
        checkpoint();previous=project_test_history_read(store,ctx;category=:persistence)
        previous["revision"]==revision || throw(ShenScopeError(:conflict,"Saved test history revision changed; refresh before writing"))
        f(previous)
    end
end

function project_test_history_publish(store::ProjectTestHistoryStore,ctx::RuntimeContext,previous,entries;action,run_id)
    value=Dict{String,Any}("schema"=>PROJECT_TEST_HISTORY_SCHEMA,"owner"=>project_test_history_owner(store),
        "revision"=>previous["revision"]+1,"entries"=>sort!(deepcopy(entries);by=entry->entry["run_id"]))
    value["sha256"]=digest(bounded_canonical_json(value;maximum=store.limits.snapshot_bytes-128,max_depth=24,max_nodes=1_000_000))
    project_test_history_validate(value,store,ctx)
    raw=bounded_canonical_json(value;maximum=store.limits.snapshot_bytes,max_depth=24,max_nodes=1_000_000)
    project_test_history_stage_admission(store,ctx)
    atomic_stream_write(project_test_history_path(store);maximum_bytes=store.limits.snapshot_bytes,before_publish=(bytes,result)->begin
        project_test_history_checkpoint(store,ctx,:persistence);project_test_history_guard(store,ctx)
        current=project_test_history_read(store,ctx;category=:persistence)
        current["sha256"]==previous["sha256"] || throw(ShenScopeError(:conflict,"Saved test history changed before publication"))
        true
    end) do output
        write(output,raw)
    end
    receipt=Dict("revision"=>value["revision"],"history_sha256"=>value["sha256"],"reports"=>length(entries),
        "action"=>String(action),"run_id"=>String(run_id))
    notification_failed=false
    try;emit!(ctx,:testing_history_committed,receipt)
    catch;notification_failed=true;end
    # Publication is already durable. Cancellation or a disconnected sink after
    # this point can suppress delivery, but cannot roll back or replay a test.
    merge(project_test_history_metadata(value,store),Dict("changed"=>true,"action"=>String(action),
        "run_id"=>String(run_id),"publication_committed"=>true,"notification_failed"=>notification_failed))
end

function save_project_test_history!(store::ProjectTestHistoryStore,manager::ProjectTestManager,run_id,ctx::RuntimeContext;
        expected_revision,label=nothing)
    report=read_project_test_report(manager,run_id,ctx)
    bytes=project_test_history_report(report,store,ctx)
    title=project_test_text(label===nothing ? report["command"]["label"] : label,"saved result label",512)
    project_test_history_transaction(store,ctx,expected_revision) do previous
        position=findfirst(entry->entry["run_id"]==report["run_id"],previous["entries"])
        if position!==nothing
            entry=previous["entries"][position]
            entry["report"]["sha256"]==report["sha256"] || throw(ShenScopeError(:conflict,"Saved run ID already has different evidence"))
            entry["label"]==title || throw(ShenScopeError(:conflict,"Use history_label to rename an already saved result"))
            project_test_history_checkpoint(store,ctx,:persistence)
            return merge(project_test_history_metadata(previous,store),Dict("changed"=>false,"run_id"=>report["run_id"],"publication_committed"=>false))
        end
        length(previous["entries"])<store.limits.reports || throw(ShenScopeError(:capacity,"Saved test report limit reached; delete a selected record before saving"))
        entries=deepcopy(previous["entries"])
        push!(entries,Dict("run_id"=>report["run_id"],"label"=>title,"saved_at"=>utcstamp(),"report_bytes"=>bytes,"report"=>report))
        project_test_history_publish(store,ctx,previous,entries;action="save",run_id=report["run_id"])
    end
end
function label_project_test_history!(store::ProjectTestHistoryStore,run_id,label,ctx::RuntimeContext;expected_revision)
    title=project_test_text(label,"saved result label",512)
    project_test_history_transaction(store,ctx,expected_revision) do previous
        entries=deepcopy(previous["entries"]);entry=project_test_history_entry(Dict("entries"=>entries),run_id)
        if entry["label"]==title
            project_test_history_checkpoint(store,ctx,:persistence)
            return merge(project_test_history_metadata(previous,store),Dict("changed"=>false,"run_id"=>entry["run_id"],"publication_committed"=>false))
        end
        entry["label"]=title
        project_test_history_publish(store,ctx,previous,entries;action="label",run_id=entry["run_id"])
    end
end
function delete_project_test_history!(store::ProjectTestHistoryStore,run_id,ctx::RuntimeContext;expected_revision)
    project_test_history_transaction(store,ctx,expected_revision) do previous
        entry=project_test_history_entry(previous,run_id)
        entries=filter(item->item["run_id"]!=entry["run_id"],previous["entries"])
        project_test_history_publish(store,ctx,previous,entries;action="delete",run_id=entry["run_id"])
    end
end
