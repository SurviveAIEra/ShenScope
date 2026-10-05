struct DiagnosticsTool <: AbstractTool
    operations::OperationManager
end
DiagnosticsTool()=DiagnosticsTool(OperationManager(;event_prefix="diagnostics",max_running=2,
    max_jobs=16,max_result_bytes=COMPILER_ARCHIVE_ASSET_BYTES+4096,max_retained_bytes=8*1024^2,
    max_result_depth=64,max_result_nodes=600_000))
tool_name(::DiagnosticsTool)="diagnostics"
tool_description(::DiagnosticsTool)="Inspect Julia contracts and ambiguities, infer fixed trusted Core methods, and manage conversation-owned compiler report archives. Graphs and comparisons describe compiler observations, without project inference, target execution or measured performance claims."
tool_schema(::DiagnosticsTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["contracts","ambiguities","targets","compile","compile_archive","compiler_source",COMPILER_ARCHIVE_ACTIONS...]),
    "target"=>Dict("type"=>"string","enum"=>[target.name for target in compiler_targets()]),
    "mode"=>Dict("type"=>"string","enum"=>["typed","lowered","graph"]),
    "timeout"=>Dict("type"=>"number","minimum"=>0.1,"maximum"=>120),
    "max_ir_bytes"=>merge(integer_schema(1024,128*1024),Dict("description"=>"Bounds typed/lowered text; graph mode has independent statement and 2 MiB JSON limits.")),
    "max_statements"=>integer_schema(1,4096),
    "method_index"=>integer_schema(1,8),"statement_id"=>integer_schema(0,4096),"context_lines"=>integer_schema(0,20),
    "job_id"=>string_schema(;max=128),"report_id"=>string_schema(;max=64),
    "before_id"=>string_schema(;max=64),"after_id"=>string_schema(;max=64),
    "title"=>string_schema(;max=512),"expected_revision"=>integer_schema(0,typemax(Int)-1),
    "expected_index_sha256"=>string_schema(;max=64),"offset"=>integer_schema(0,10_000),
    "limit"=>integer_schema(1,512),"dry_run"=>Dict("type"=>"boolean"));required=["action"])
function execute(tool::DiagnosticsTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    diagnostics_arguments(args)
    action=="compiler_source" && return diagnostics_compiler_source(tool,args,ctx)
    action=="compile_archive" && return diagnostics_compile_archive(args,ctx)
    action in COMPILER_ARCHIVE_ACTIONS && return diagnostics_archive_execute(tool,args,ctx)
    authorize!(ctx,:read,"runtime.diagnostics",ctx.root)
    action=="contracts" && return interface_catalog()
    action=="ambiguities" && return dispatch_ambiguities(;ctx)
    action=="targets" && return [Dict("name"=>t.name,"arguments"=>string(t.arguments)) for t in compiler_targets()]
    action=="compile" || throw(ShenScopeError(:diagnostics,"Unknown diagnostics action"))
    haskey(args,"target") || throw(ShenScopeError(:diagnostics,"Compiler target required"))
    run_compiler_diagnostic(ctx,args["target"];mode=get(args,"mode","typed"),timeout=get(args,"timeout",60.0),
        max_ir_bytes=get(args,"max_ir_bytes",64*1024),max_statements=get(args,"max_statements",2048))
end
