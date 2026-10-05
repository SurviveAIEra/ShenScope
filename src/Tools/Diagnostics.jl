struct DiagnosticsTool <: AbstractTool
    operations::OperationManager
end
DiagnosticsTool()=DiagnosticsTool(OperationManager(;event_prefix="diagnostics",max_running=2,
    max_jobs=16,max_result_bytes=COMPILER_ARCHIVE_ASSET_BYTES+4096,max_retained_bytes=8*1024^2,
    max_result_depth=64,max_result_nodes=600_000))
tool_name(::DiagnosticsTool)="diagnostics"
tool_description(::DiagnosticsTool)="Inspect Julia contracts, fixed-method inferred IR and owned report archives with verified source previews. Profile measures allocations; sample collects bounded periodic backtraces. Both execute one of three fixed Core fixtures in a separate host process. Inspect executes inference and profiling then associates their source positions with JuliaSyntax declarations; evidence reads existing owned compiler, profile or sampling jobs without execution. Source joins are candidates, not runtime bindings or semantic-equivalence proofs. Sample fractions are inclusive occurrences, not CPU utilization. No arbitrary project loading or performance-improvement claim."
tool_schema(::DiagnosticsTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["contracts","ambiguities","targets","compile","compile_archive","compiler_source","profile","sample","inspect","evidence","evidence_source",COMPILER_ARCHIVE_ACTIONS...]),
    "target"=>Dict("type"=>"string","enum"=>[target.name for target in compiler_targets()]),
    "mode"=>Dict("type"=>"string","enum"=>["typed","lowered","graph"]),
    "timeout"=>Dict("type"=>"number","minimum"=>0.1,"maximum"=>120),
    "max_ir_bytes"=>merge(integer_schema(1024,128*1024),Dict("description"=>"Bounds typed/lowered text; graph mode has independent statement and 2 MiB JSON limits.")),
    "max_statements"=>integer_schema(1,4096),
    "fixture"=>Dict("type"=>"string","enum"=>["default","small_ascii","unicode","nested_dictionary"]),
    "iterations"=>integer_schema(1,32),"repetitions"=>integer_schema(1,8),
    "max_samples"=>integer_schema(1,256),"max_frames"=>integer_schema(1,8),
    "sample_rate"=>Dict("type"=>"number","minimum"=>0.001,"maximum"=>1),
    "duration_seconds"=>Dict("type"=>"number","minimum"=>0.01,"maximum"=>1),
    "delay_seconds"=>Dict("type"=>"number","minimum"=>0.0001,"maximum"=>0.01),
    "buffer_words"=>integer_schema(4096,200_000),
    "compiler_job_id"=>string_schema(;max=128),"profile_job_id"=>string_schema(;max=128),"sampling_job_id"=>string_schema(;max=128),
    "expected_evidence_sha256"=>string_schema(;max=64),"observation_key"=>string_schema(;max=64),
    "query"=>string_schema(;max=256),"observation_kind"=>Dict("type"=>"string","enum"=>collect(RUNTIME_EVIDENCE_KINDS)),
    "method_index"=>integer_schema(1,8),"statement_id"=>integer_schema(0,4096),"context_lines"=>integer_schema(0,20),
    "job_id"=>string_schema(;max=128),"report_id"=>string_schema(;max=64),
    "before_id"=>string_schema(;max=64),"after_id"=>string_schema(;max=64),
    "title"=>string_schema(;max=512),"expected_revision"=>integer_schema(0,typemax(Int)-1),
    "expected_index_sha256"=>string_schema(;max=64),"offset"=>integer_schema(0,40_000),
    "limit"=>integer_schema(1,512),"dry_run"=>Dict("type"=>"boolean"));required=["action"])
function execute(tool::DiagnosticsTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    diagnostics_arguments(args)
    action in ("evidence","evidence_source") && return diagnostics_runtime_evidence(tool,args,ctx)
    action=="compiler_source" && return diagnostics_compiler_source(tool,args,ctx)
    action=="compile_archive" && return diagnostics_compile_archive(args,ctx)
    action in COMPILER_ARCHIVE_ACTIONS && return diagnostics_archive_execute(tool,args,ctx)
    authorize!(ctx,:read,"runtime.diagnostics",ctx.root)
    action=="contracts" && return interface_catalog()
    action=="ambiguities" && return dispatch_ambiguities(;ctx)
    action=="targets" && return [Dict("name"=>t.name,"arguments"=>string(t.arguments)) for t in compiler_targets()]
    action=="inspect" && return diagnostics_inspect(args,ctx)
    action=="sample" && return run_sampling_diagnostic(ctx,args["target"];fixture=get(args,"fixture","default"),
        timeout=get(args,"timeout",60.0),iterations=get(args,"iterations",8),duration_seconds=get(args,"duration_seconds",0.1),
        delay_seconds=get(args,"delay_seconds",0.001),max_samples=get(args,"max_samples",128),
        max_frames=get(args,"max_frames",4),buffer_words=get(args,"buffer_words",20_000))
    action=="profile" && return run_profile_diagnostic(ctx,args["target"];fixture=get(args,"fixture","default"),
        timeout=get(args,"timeout",60.0),iterations=get(args,"iterations",8),repetitions=get(args,"repetitions",3),
        max_samples=get(args,"max_samples",128),max_frames=get(args,"max_frames",4),sample_rate=get(args,"sample_rate",1.0))
    action=="compile" || throw(ShenScopeError(:diagnostics,"Unknown diagnostics action"))
    haskey(args,"target") || throw(ShenScopeError(:diagnostics,"Compiler target required"))
    run_compiler_diagnostic(ctx,args["target"];mode=get(args,"mode","typed"),timeout=get(args,"timeout",60.0),
        max_ir_bytes=get(args,"max_ir_bytes",64*1024),max_statements=get(args,"max_statements",2048))
end
