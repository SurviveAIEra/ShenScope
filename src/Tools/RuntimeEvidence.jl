function diagnostics_owned_runtime_report(tool,job_id,ctx::RuntimeContext,kind::String)
    view=owned_operation(tool.operations,job_id,ctx)
    action_ok=kind=="compiler" ? view["action"] in ("compile","compile_archive") : view["action"]=="profile"
    mode=kind=="compiler" ? "graph" : "profile"
    action_ok && view["status"]=="complete" && view["result"] isa AbstractDict &&
        get(view["metadata"],"mode",nothing)==mode ||
        throw(ShenScopeError(:diagnostics,"Runtime evidence requires an owned completed "*kind*" job"))
    report=get(view["result"],"report",nothing)
    report isa AbstractDict || throw(ShenScopeError(:diagnostics,"Owned runtime report is missing"))
    report
end

function diagnostics_runtime_evidence(tool,args::AbstractDict,ctx::RuntimeContext)
    if args["action"]=="evidence_source"
        compiler_archive_hash(args["observation_key"],"runtime observation key")
        compiler_archive_hash(args["expected_evidence_sha256"],"required runtime evidence fingerprint")
        compiler_ir_integer(get(args,"context_lines",4),"preview context lines",0,20)
    else
        runtime_evidence_query_parameters(;offset=get(args,"offset",0),limit=get(args,"limit",40),
            query=get(args,"query",""),observation_kind=get(args,"observation_kind","all"))
    end
    root=runtime_core_root()
    authorize!(ctx,:read,"runtime.diagnostics",root;reason="Read owned reports and hash-verified installed Core declaration facts")
    compiler=haskey(args,"compiler_job_id") ? diagnostics_owned_runtime_report(tool,args["compiler_job_id"],ctx,"compiler") : nothing
    profile=haskey(args,"profile_job_id") ? diagnostics_owned_runtime_report(tool,args["profile_job_id"],ctx,"profile") : nothing
    snapshot=runtime_source_snapshot(ctx;root,authorized=true)
    evidence=runtime_evidence_build(compiler,profile,snapshot,ctx;authorized=true)
    expected=get(args,"expected_evidence_sha256",nothing)
    if args["action"]=="evidence_source"
        return runtime_evidence_source(evidence,args["observation_key"],ctx;
            expected_evidence_sha256=expected,context_lines=get(args,"context_lines",4))
    end
    runtime_evidence_page(evidence,ctx;offset=get(args,"offset",0),limit=get(args,"limit",40),
        query=get(args,"query",""),observation_kind=get(args,"observation_kind","all"),expected_evidence_sha256=expected)
end

function diagnostics_inspect(args::AbstractDict,ctx::RuntimeContext)
    runtime_evidence_query_parameters(;offset=get(args,"offset",0),limit=get(args,"limit",40),
        query=get(args,"query",""),observation_kind=get(args,"observation_kind","all"))
    name=args["target"];compiler_profile_target(name)
    compiler_profile_fixture(name,get(args,"fixture","default"))
    CompilerProfileLimits(;iterations=get(args,"iterations",8),repetitions=get(args,"repetitions",3),
        max_samples=get(args,"max_samples",128),max_frames=get(args,"max_frames",4),sample_rate=get(args,"sample_rate",1.0))
    inferred=run_compiler_diagnostic(ctx,name;mode="graph",timeout=get(args,"timeout",60.0))
    measured=run_profile_diagnostic(ctx,name;fixture=get(args,"fixture","default"),timeout=get(args,"timeout",60.0),
        iterations=get(args,"iterations",8),repetitions=get(args,"repetitions",3),max_samples=get(args,"max_samples",128),
        max_frames=get(args,"max_frames",4),sample_rate=get(args,"sample_rate",1.0))
    snapshot=runtime_source_snapshot(ctx;root=runtime_core_root(),authorized=true)
    evidence=runtime_evidence_build(inferred["report"],measured["report"],snapshot,ctx;authorized=true)
    result=runtime_evidence_page(evidence,ctx;offset=get(args,"offset",0),limit=get(args,"limit",40),
        query=get(args,"query",""),observation_kind=get(args,"observation_kind","all"))
    result["execution"]=Dict("separate_processes"=>2,"os_sandbox"=>false,"project_loading"=>false)
    result
end
