const PROJECT_TEST_EDITOR_CATALOG_SCHEMA="shenscope.editor-test-catalog/1"
const PROJECT_TEST_EDITOR_RESULT_SCHEMA="shenscope.editor-test-result/1"
const PROJECT_TEST_EDITOR_RESULT_BYTES=192*1024

function project_test_editor_catalog(manager::ProjectTestManager,catalog_id,ctx::RuntimeContext)
    catalog=read_project_test_catalog(manager,catalog_id,ctx)
    commands=[Dict("id"=>candidate["id"],"label"=>candidate["label"],"language"=>candidate["language"],
        "cwd"=>candidate["cwd"],"framework"=>candidate["framework"],"confidence"=>candidate["confidence"],
        "declaration_paths"=>[marker["path"] for marker in candidate["markers"]],"kind"=>"command",
        "description"=>"Runs a declared or suggested project command; not an enumerated individual test.") for candidate in catalog["candidates"]]
    project_test_checkpoint(ctx;read_target=ctx.root)
    Dict("schema"=>PROJECT_TEST_EDITOR_CATALOG_SCHEMA,"session_id"=>ctx.session_id,"root_sha256"=>digest(ctx.root),
        "catalog_id"=>catalog["catalog_id"],"collection_id"=>digest(canonical(Dict("workspace"=>digest(ctx.root),"session"=>ctx.session_id))),
        "commands"=>commands,"coverage"=>deepcopy(catalog["coverage"]),"automatic_execution"=>false,
        "individual_test_discovery"=>false,"command_selection_bound"=>16,
        "case_identity"=>"Cases observed after a run have receipt-scoped identities, not stable project-wide test identities.")
end

function project_test_editor_state(outcome)
    outcome=="command_succeeded" && return "passed"
    outcome in ("command_failed","reported_failure") && return "failed"
    outcome=="cancelled" && return "skipped"
    "errored"
end
function project_test_editor_case_state(status)
    status=="passed" && return "passed"
    status in ("failed","unexpected_success") && return "failed"
    status in ("skipped","expected_failure") && return "skipped"
    "errored"
end
function project_test_editor_output(text::String,maximum::Int)
    # Editor result logs receive plain output. Raw terminal escapes and control
    # bytes remain in the original receipt and are not interpreted as UI links.
    plain=replace(text,r"\e\][^\a\e]*(?:\a|\e\\)"=>"",r"\e\[[0-?]*[ -/]*[@-~]"=>"",r"[\x00-\x08\x0b-\x1f\x7f]"=>"")
    cliptext(plain,maximum)
end
function project_test_editor_report(report::AbstractDict;case_limit=32,frame_limit=16,output_limit=8192)
    cases=project_test_integer(case_limit,"editor case limit",0,128)
    frames=project_test_integer(frame_limit,"editor source reference limit",0,64)
    output=project_test_integer(output_limit,"editor output byte limit",64,32768)
    observed=report["parsed"]["cases"]
    projected=[Dict("id"=>digest(report["run_id"]*":"*case["id"]),"reported_case_id"=>case["id"],
        "label"=>case["name"],"suite"=>case["suite"],"reported_status"=>case["status"],
        "state"=>project_test_editor_case_state(case["status"]),"duration_seconds"=>case["duration_seconds"],
        "details"=>cliptext(case["details"],512),"source"=>"framework_reported","runnable_individually"=>false)
        for case in observed[1:min(cases,end)]]
    value=Dict{String,Any}("schema"=>PROJECT_TEST_EDITOR_RESULT_SCHEMA,"run_id"=>report["run_id"],"report_sha256"=>report["sha256"],
        "candidate_id"=>report["command"]["id"],"label"=>report["command"]["label"],"outcome"=>report["outcome"],
        "state"=>project_test_editor_state(report["outcome"]),"exit_code"=>report["exit_code"],
        "duration_seconds"=>report["process"]["elapsed_seconds"],"cases"=>projected,
        "observed_case_counts"=>deepcopy(report["parsed"]["observed_case_counts"]),"receipt_cases_retained"=>length(observed),
        "source_references"=>deepcopy(report["parsed"]["frames"][1:min(frames,end)]),
        "stdout"=>project_test_editor_output(report["process"]["stdout"],output),
        "stderr"=>project_test_editor_output(report["process"]["stderr"],output),
        "projection_truncated"=>length(observed)>cases || length(report["parsed"]["frames"])>frames ||
            ncodeunits(report["process"]["stdout"])>output || ncodeunits(report["process"]["stderr"])>output,
        "receipt_interpretation_complete"=>report["parsed"]["interpretation_complete"],
        "complete_project_coverage"=>false,"case_results_independently_verified"=>false,
        "case_source_associations_verified"=>false,"automatic_replay"=>false,
        "description"=>"Command state describes observed process/framework outcome. Child case states are framework reports; references are not assigned to individual cases.")
    for attempt in 1:16
        try
            bounded_canonical_json(value;maximum=PROJECT_TEST_EDITOR_RESULT_BYTES,max_depth=16,max_nodes=16384)
            return value
        catch cause
            cause isa ShenScopeError && cause.code==:capacity || rethrow()
        end
        value["projection_truncated"]=true
        if !isempty(value["cases"])
            resize!(value["cases"],div(length(value["cases"]),2))
        elseif !isempty(value["source_references"])
            resize!(value["source_references"],div(length(value["source_references"]),2))
        else
            for field in ("stdout","stderr");value[field]=cliptext(value[field],max(64,div(ncodeunits(value[field]),2)));end
        end
    end
    throw(ShenScopeError(:capacity,"Editor test result cannot fit its projection bound"))
end

function project_test_editor_result(manager::ProjectTestManager,run_id,ctx::RuntimeContext;kwargs...)
    report=read_project_test_report(manager,run_id,ctx)
    value=project_test_editor_report(report;kwargs...)
    project_test_checkpoint(ctx;read_target=ctx.root);value
end
