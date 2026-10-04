struct SecurityTool <: AbstractTool
    manager::ExecutionManager
end
SecurityTool()=SecurityTool(ExecutionManager())
tool_name(::SecurityTool)="security"
tool_description(::SecurityTool)="Read execution policy metadata or explicitly probe Linux isolation. Probes never grant permissions or fall back to host execution."
execution_mode(::SecurityTool)=:exclusive
tool_schema(::SecurityTool)=object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["status","probe"]));required=["action"])

function execute(tool::SecurityTool,args::AbstractDict,ctx::RuntimeContext)
    validate_schema(args,tool_schema(tool))
    all(key->key=="action",keys(args)) || throw(ShenScopeError(:arguments,"Unknown security argument"))
    args["action"]=="status" ? execution_status(tool.manager,ctx) : execution_probe!(tool.manager,ctx)
end
