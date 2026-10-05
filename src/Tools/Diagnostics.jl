struct DiagnosticsTool <: AbstractTool
    operations::OperationManager
end
DiagnosticsTool()=DiagnosticsTool(OperationManager(;event_prefix="diagnostics",max_running=2,
    max_jobs=16,max_result_bytes=COMPILER_IR_MAX_BYTES+4096,max_retained_bytes=8*1024^2))
tool_name(::DiagnosticsTool)="diagnostics"
tool_description(::DiagnosticsTool)="Inspect Julia contracts and ambiguities, or infer listed trusted Core methods in a separate process. Graph mode returns bounded control flow, possible local definitions, types and experimental effects; it provides no runtime trace or project inference."
tool_schema(::DiagnosticsTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["contracts","ambiguities","targets","compile"]),
    "target"=>Dict("type"=>"string","enum"=>[target.name for target in compiler_targets()]),
    "mode"=>Dict("type"=>"string","enum"=>["typed","lowered","graph"]),
    "timeout"=>Dict("type"=>"number","minimum"=>0.1,"maximum"=>120),
    "max_ir_bytes"=>merge(integer_schema(1024,128*1024),Dict("description"=>"Bounds typed/lowered text; graph mode has independent statement and 2 MiB JSON limits.")),
    "max_statements"=>integer_schema(1,4096));required=["action"])
function execute(::DiagnosticsTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    authorize!(ctx,:read,"runtime.diagnostics",ctx.root)
    action=="contracts" && return interface_catalog()
    action=="ambiguities" && return dispatch_ambiguities(;ctx)
    action=="targets" && return [Dict("name"=>t.name,"arguments"=>string(t.arguments)) for t in compiler_targets()]
    action=="compile" || throw(ShenScopeError(:diagnostics,"Unknown diagnostics action"))
    haskey(args,"target") || throw(ShenScopeError(:diagnostics,"Compiler target required"))
    run_compiler_diagnostic(ctx,args["target"];mode=get(args,"mode","typed"),timeout=get(args,"timeout",60.0),
        max_ir_bytes=get(args,"max_ir_bytes",64*1024),max_statements=get(args,"max_statements",2048))
end
