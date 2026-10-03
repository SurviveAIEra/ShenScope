struct DiagnosticsTool <: AbstractTool end
tool_name(::DiagnosticsTool)="diagnostics"
tool_description(::DiagnosticsTool)="Inspect loaded Julia extension contracts and dispatch ambiguities; explicitly permitted compiler diagnostics run separately on listed Core methods."
tool_schema(::DiagnosticsTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["contracts","ambiguities","targets","compile"]),
    "target"=>Dict("type"=>"string","enum"=>[target.name for target in compiler_targets()]),
    "mode"=>Dict("type"=>"string","enum"=>["typed","lowered"]),
    "timeout"=>Dict("type"=>"number","minimum"=>0.1,"maximum"=>120),
    "max_ir_bytes"=>integer_schema(1024,128*1024));required=["action"])
function execute(::DiagnosticsTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    authorize!(ctx,:read,"runtime.diagnostics",ctx.root)
    action=="contracts" && return interface_catalog()
    action=="ambiguities" && return dispatch_ambiguities(;ctx)
    action=="targets" && return [Dict("name"=>t.name,"arguments"=>string(t.arguments)) for t in compiler_targets()]
    action=="compile" || throw(ShenScopeError(:diagnostics,"Unknown diagnostics action"))
    haskey(args,"target") || throw(ShenScopeError(:diagnostics,"Compiler target required"))
    run_compiler_diagnostic(ctx,args["target"];mode=get(args,"mode","typed"),timeout=get(args,"timeout",60.0),max_ir_bytes=get(args,"max_ir_bytes",64*1024))
end
