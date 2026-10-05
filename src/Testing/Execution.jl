function run_project_test_candidate!(manager::ProjectTestManager,candidate::ProjectTestCandidate,ctx::RuntimeContext;
        catalog_id=nothing,timeout=120.0,output_limit=256*1024)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05<=timeout<=3600 || throw(ShenScopeError(:testing,"Invalid test timeout"))
    cap=project_test_integer(output_limit,"test stream output bound",64,1024^2)
    # Reserve enough room for both retained streams and bounded interpretations.
    2*cap+1024*1024<=manager.max_report_bytes || throw(ShenScopeError(:capacity,"Output bound is too large for this manager's report capacity"))
    authorize!(ctx,:read,"testing",ctx.root;reason="Read the selected test declaration and captured result")
    cwd=validate_project_test_candidate(candidate,ctx)
    bounded_canonical_json(project_test_candidate_view(candidate);maximum=min(256*1024,div(manager.max_report_bytes,4)))
    target=canonical(Dict("purpose"=>"project_test","catalog_id"=>catalog_id,"candidate"=>project_test_candidate_view(candidate)))
    started=utcstamp()
    handle=start_process!(manager.processes,copy(candidate.argv),ctx;cwd,timeout,output_limit=cap,emit_output=false,
        permission_target=target,permission_tool="testing",before_start=()->validate_project_test_candidate(candidate,ctx))
    process=try
        close(handle.input);wait(handle.monitor);process_status(handle)
    finally
        !istaskdone(handle.monitor) && (terminate_process!(handle);wait(handle.monitor))
        lock(manager.processes.mutex) do;delete!(manager.processes.handles,handle.id);end
    end
    parsed=parse_project_test_output(candidate.framework,process["stdout"],process["stderr"],ctx,cwd)
    out_truncated=process["stdout_bytes"]>cap;err_truncated=process["stderr_bytes"]>cap
    process["stdout_truncated"]=out_truncated;process["stderr_truncated"]=err_truncated
    parsed["captured_streams_complete"]=!out_truncated && !err_truncated
    parsed["interpretation_complete"]=!out_truncated && !err_truncated && !parsed["cases_truncated"] &&
        !parsed["frames_truncated"] && !parsed["lines_truncated"] && parsed["invalid_records"]==0
    parsed["individual_cases_observed"]=!isempty(parsed["cases"])
    cancelled=iscancelled(ctx.cancellation)
    report=Dict{String,Any}("schema"=>PROJECT_TEST_REPORT_SCHEMA,"run_id"=>string(uuid4()),"created_at"=>started,
        "finished_at"=>utcstamp(),"session_id"=>ctx.session_id,"root_sha256"=>digest(ctx.root),"catalog_id"=>catalog_id,
        "command"=>project_test_candidate_view(candidate),"process"=>process,"parsed"=>parsed,
        "exit_code"=>process["exit_code"],"timed_out"=>process["timed_out"],"cancelled"=>cancelled,
        "permission_revoked"=>process["permission_revoked"],"outcome"=>project_test_report_outcome(process,parsed,cancelled),
        "execution_source_snapshot_verified"=>false,"automatic_replay"=>false,
        "limitations"=>["The Core observed a process result. Case outcomes and summaries are framework-reported output, not independent correctness proof.",
            "A zero exit code does not prove any tests were collected or the whole project was tested.",
            "Only selected project marker content is rechecked before launch; other source files can change during execution.",
            "Controller retention is bounded and in memory. Explicit history_save persists an owned receipt separately with Persistence permission and revision checks; reading it never replays the command."])
    report["sha256"]=digest(fit_project_test_report!(report,manager.max_report_bytes))
    # Preserve the execution receipt even when cancellation or a revoked output
    # read prevents delivery. A query can retrieve it after an explicit policy
    # change. Never retry a process because report delivery was interrupted.
    retain_project_test_report!(manager,report,ctx)
    permission_decision(ctx.permissions,PermissionRequest("testing-result-current",:read,"testing",ctx.root,"Read captured test result"))!=Deny ||
        throw(ShenScopeError(:permission,"Test executed but its captured result is now denied; no replay was attempted"))
    report
end

function run_project_tests!(manager::ProjectTestManager,ctx::RuntimeContext;catalog_id,candidate_id,kwargs...)
    catalog,candidate=select_project_test_candidate(manager,catalog_id,candidate_id,ctx)
    run_project_test_candidate!(manager,candidate,ctx;catalog_id=catalog.id,kwargs...)
end

function run_project_test_command!(manager::ProjectTestManager,ctx::RuntimeContext;argv,cwd=".",framework="raw",label="Explicit test command",kwargs...)
    candidate=project_test_custom_candidate(ctx,argv;cwd,framework,label)
    run_project_test_candidate!(manager,candidate,ctx;kwargs...)
end
