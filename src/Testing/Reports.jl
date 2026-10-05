function retain_project_test_report!(manager::ProjectTestManager,report::Dict{String,Any},ctx::RuntimeContext)
    bytes=ncodeunits(bounded_canonical_json(report;maximum=manager.max_report_bytes,max_depth=20,max_nodes=100_000))
    id=report["run_id"]
    lock(manager.mutex) do
        retained=sum(entry[3] for entry in values(manager.reports);init=0)
        ordered=sort!(collect(keys(manager.reports));by=key->(manager.reports[key][2]["created_at"],key))
        while length(manager.reports)>=manager.max_reports || retained+bytes>manager.max_retained_bytes
            isempty(ordered) && throw(ShenScopeError(:capacity,"Project test report exceeds available retention"))
            key=popfirst!(ordered);retained-=manager.reports[key][3];delete!(manager.reports,key)
        end
        manager.reports[id]=(operation_scope(ctx),deepcopy(report),bytes)
    end
    nothing
end

function owned_project_test_report(manager::ProjectTestManager,id,ctx::RuntimeContext)
    key=project_test_text(id,"test run ID",128)
    lock(manager.mutex) do
        entry=get(manager.reports,key,nothing)
        entry===nothing && throw(ShenScopeError(:testing,"Test report does not exist or has been retired"))
        entry[1]==operation_scope(ctx) || throw(ShenScopeError(:permission,"Test report belongs to another conversation or workspace"))
        deepcopy(entry[2])
    end
end

function read_project_test_report(manager::ProjectTestManager,id,ctx::RuntimeContext)
    authorize!(ctx,:read,"testing",ctx.root;reason="Read captured output from an owned test execution")
    value=owned_project_test_report(manager,id,ctx)
    project_test_checkpoint(ctx;read_target=ctx.root)
    value
end

function list_project_test_reports(manager::ProjectTestManager,ctx::RuntimeContext;limit=16)
    bound=project_test_integer(limit,"test report list bound",1,32)
    authorize!(ctx,:read,"testing",ctx.root;reason="List retained test executions in this conversation")
    result=lock(manager.mutex) do
        entries=[entry[2] for entry in values(manager.reports) if entry[1]==operation_scope(ctx)]
        sort!(entries;by=value->(value["created_at"],value["run_id"]),rev=true)
        summaries=[Dict("run_id"=>value["run_id"],"sha256"=>value["sha256"],"created_at"=>value["created_at"],
            "label"=>value["command"]["label"],"outcome"=>value["outcome"],"exit_code"=>value["exit_code"],
            "framework"=>value["parsed"]["framework"],"cases_observed"=>length(value["parsed"]["cases"])) for value in entries[1:min(bound,end)]]
        Dict("reports"=>summaries,"has_more"=>length(entries)>bound,"retention"=>"bounded_in_memory",
            "automatic_replay"=>false,"survives_server_restart"=>false)
    end
    project_test_checkpoint(ctx;read_target=ctx.root)
    result
end

function project_test_report_outcome(process,parsed,cancelled)
    process["timed_out"] && return "timed_out"
    process["permission_revoked"] && return "permission_revoked"
    cancelled && return "cancelled"
    process["signal"]!=0 && return "signalled"
    process["exit_code"]!=0 && return "command_failed"
    counts=parsed["observed_case_counts"];summary=parsed["framework_summary"]
    failures=sum(get(counts,key,0) for key in ("failed","error","unexpected_success"))
    summary_failed=get(summary,"status",nothing)=="failed" || haskey(summary,"bailout") ||
        any(get(summary,key,0)>0 for key in ("failures","failed","errors","xpassed","unexpected_successes","packages_failed"))
    failures>0 || summary_failed ? "reported_failure" : "command_succeeded"
end

function project_test_report_body(value::AbstractDict)
    Dict{String,Any}(key=>deepcopy(item) for (key,item) in value if key!="sha256")
end

function fit_project_test_report!(report::Dict{String,Any},maximum::Int)
    parsed=report["parsed"];process=report["process"]
    # JSON escaping can expand terminal control bytes. Limit the serialized
    # receipt as well as raw capture, preserving the process outcome throughout.
    for attempt in 1:32
        try
            return bounded_canonical_json(report;maximum=maximum-128,max_depth=20,max_nodes=100_000)
        catch cause
            cause isa ShenScopeError && cause.code==:capacity || rethrow()
        end
        parsed["interpretation_complete"]=false
        if !isempty(parsed["cases"])
            resize!(parsed["cases"],div(length(parsed["cases"]),2));parsed["cases_truncated"]=true
            parsed["observed_case_counts"]=Dict(status=>count(case->case["status"]==status,parsed["cases"]) for status in PROJECT_TEST_CASE_STATUSES)
            parsed["individual_cases_observed"]=!isempty(parsed["cases"])
        elseif !isempty(parsed["frames"])
            resize!(parsed["frames"],div(length(parsed["frames"]),2));parsed["frames_truncated"]=true
        elseif haskey(parsed["framework_summary"],"packages") && !isempty(parsed["framework_summary"]["packages"])
            parsed["framework_summary"]["packages"]=Dict();parsed["framework_summary"]["package_details_omitted"]=true
        elseif !isempty(process["stdout"]) || !isempty(process["stderr"])
            stream=ncodeunits(process["stdout"])>=ncodeunits(process["stderr"]) ? "stdout" : "stderr"
            text=process[stream];process[stream]=first(text,div(length(text),2))
            process[stream*"_truncated"]=true;parsed["captured_streams_complete"]=false
        else
            throw(ShenScopeError(:capacity,"Execution receipt metadata exceeds the configured capacity"))
        end
        report["receipt_trimmed_for_transport"]=true
    end
    throw(ShenScopeError(:capacity,"Unable to bound execution receipt"))
end

function cleanup_project_tests!(manager::ProjectTestManager;session_id=nothing,root=nothing)
    owners=lock(manager.processes.mutex) do
        unique([handle.owner for handle in values(manager.processes.handles) if session_id===nothing || handle.owner==session_id])
    end
    for owner in owners;cleanup_processes!(manager.processes,owner);end
    lock(manager.mutex) do
        matches=scope->(session_id===nothing || scope[3]==session_id) && (root===nothing || scope[1]==root)
        for key in collect(keys(manager.catalogs));matches(manager.catalogs[key][1]) && delete!(manager.catalogs,key);end
        for key in collect(keys(manager.reports));matches(manager.reports[key][1]) && delete!(manager.reports,key);end
    end
    nothing
end
