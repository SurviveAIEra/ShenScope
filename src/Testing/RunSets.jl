const PROJECT_TEST_RUN_SET_SCHEMA="shenscope.project-test-run-set/1"

function run_project_test_set!(manager::ProjectTestManager,ctx::RuntimeContext;catalog_id,candidate_ids,
        stop_on_failure=false,timeout=120.0,output_limit=64*1024)
    candidate_ids isa AbstractVector && 1<=length(candidate_ids)<=16 || throw(ShenScopeError(:testing,"Select between one and sixteen test commands"))
    ids=[project_test_history_hash(value,"selected test candidate identity") for value in candidate_ids]
    length(unique(ids))==length(ids) || throw(ShenScopeError(:testing,"Selected test command identities must be unique"))
    stop_on_failure isa Bool || throw(ShenScopeError(:testing,"Invalid stop-on-failure choice"))
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05<=timeout<=3600 || throw(ShenScopeError(:testing,"Invalid test timeout"))
    cap=project_test_integer(output_limit,"run-set stream output bound",64,128*1024)
    length(ids)<=manager.max_reports || throw(ShenScopeError(:capacity,"Selected commands exceed this manager's report count capacity"))
    receipt_limit=min(manager.max_report_bytes,512*1024,div(manager.max_retained_bytes,length(ids)))
    2*cap+min(1024^2,div(receipt_limit,2))<=receipt_limit || throw(ShenScopeError(:capacity,"Selected commands exceed available receipt byte capacity"))
    catalog=owned_project_test_catalog(manager,catalog_id,ctx)
    candidates=ProjectTestCandidate[]
    for id in ids
        position=findfirst(candidate->candidate.id==id,catalog.candidates)
        position===nothing && throw(ShenScopeError(:testing,"A selected command is absent from the owned catalog"))
        push!(candidates,catalog.candidates[position])
    end
    # Validate the whole selection before the first side effect, then recheck
    # each declaration after its independent Process approval at launch.
    authorize!(ctx,:read,"testing",ctx.root;reason="Read selected project test declarations and results")
    for candidate in candidates;validate_project_test_candidate(candidate,ctx);end
    set_id=string(uuid4());started=utcstamp();rows=Any[];not_started=String[]
    emit!(ctx,:testing_run_set_started,Dict("run_set_id"=>set_id,"catalog_id"=>catalog.id,"candidate_ids"=>copy(ids),"automatic_replay"=>false))
    for (ordinal,candidate) in enumerate(candidates)
        if iscancelled(ctx.cancellation)
            append!(not_started,ids[ordinal:end]);break
        end
        row=try
            report=run_project_test_candidate!(manager,candidate,ctx;catalog_id=catalog.id,timeout,output_limit=cap,receipt_limit)
            Dict{String,Any}("candidate_id"=>candidate.id,"ordinal"=>ordinal,"execution_receipt_available"=>true,
                "result"=>project_test_editor_report(report),"error"=>nothing)
        catch cause
            cause isa InterruptException && rethrow()
            Dict{String,Any}("candidate_id"=>candidate.id,"ordinal"=>ordinal,"execution_receipt_available"=>false,"result"=>nothing,
                "error"=>Dict("code"=>cause isa ShenScopeError ? String(cause.code) : "internal",
                    "message"=>cause isa ShenScopeError ? cliptext(cause.message,512) : "Test command did not deliver an execution receipt",
                    "execution_status"=>"unconfirmed","automatic_replay"=>false))
        end
        push!(rows,row)
        emit!(ctx,:testing_run_set_progress,Dict("run_set_id"=>set_id,"selected"=>length(ids),"completed"=>length(rows),"command"=>deepcopy(row)))
        failed=row["result"]===nothing || row["result"]["outcome"]!="command_succeeded"
        if row["result"]===nothing || iscancelled(ctx.cancellation) || failed && stop_on_failure
            ordinal<length(ids) && append!(not_started,ids[ordinal+1:end]);break
        end
    end
    result=Dict{String,Any}("schema"=>PROJECT_TEST_RUN_SET_SCHEMA,"run_set_id"=>set_id,"session_id"=>ctx.session_id,
        "root_sha256"=>digest(ctx.root),"catalog_id"=>catalog.id,"created_at"=>started,"finished_at"=>utcstamp(),
        "selected_candidate_ids"=>copy(ids),"commands"=>rows,"not_started_candidate_ids"=>not_started,
        "stop_on_failure"=>stop_on_failure,"parallel_execution"=>false,"automatic_replay"=>false,
        "outcome"=>(!isempty(not_started) || any(row->row["result"]===nothing || row["result"]["outcome"]!="command_succeeded",rows) ? "run_set_failed" : "command_succeeded"),
        "complete_project_coverage"=>false,"controller_receipts_survive_restart"=>false,
        "limitations"=>["Commands run in selection order with independent approvals and the shared budget.",
            "A missing receipt does not establish whether a command had side effects; never replay it automatically.",
            "Editor projections are bounded. Individual execution receipts remain in the manager's bounded in-memory retention."])
    result["sha256"]=digest(bounded_canonical_json(result;maximum=4*1024^2-128,max_depth=24,max_nodes=100_000))
    project_test_checkpoint(ctx;read_target=ctx.root);result
end
