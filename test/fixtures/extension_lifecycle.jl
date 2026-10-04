module ExtensionLifecycleFixtures
using ShenScope, UUIDs
import ShenScope: tool_name,tool_description,tool_schema,execute,execution_mode
mutable struct CounterTool <: AbstractTool
    calls::Base.RefValue{Int}
    schema::Dict{String,Any}
end
tool_name(::CounterTool)="counter"
tool_description(::CounterTool)="Count an independently registered tool invocation"
tool_schema(tool::CounterTool)=deepcopy(tool.schema)
execution_mode(::CounterTool)=:exclusive
execute(tool::CounterTool,args::AbstractDict,ctx::RuntimeContext)=(tool.calls[]+=1;Dict("count"=>tool.calls[],"value"=>args["value"]))
struct MissingTool <: AbstractTool end
const UUID_VALUE=UUID("c4e77152-5e6f-480b-8a7a-9fc6f6d7f6f2")
function context(root;dynamic=Allow)
    RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(
        :read=>Allow,:dynamic=>dynamic,:process=>Deny,:network=>Deny,:persistence=>Deny)))
end
function bundle(;name="counter_extension",calls=Ref(0),closed=Ref(0),fail=false,cleanup_fail=false)
    schema=ShenScope.object_schema(Dict("value"=>ShenScope.integer_schema(0,100));required=["value"])
    tool=CounterTool(calls,schema)
    cleanup=(value,ctx)->(closed[]+=1;cleanup_fail && error("private failure"))
    contributions=[ExtensionContribution("counter",:tool,ctx->tool;cleanup)]
    fail && push!(contributions,ExtensionContribution("broken",:tool,ctx->error("private factory failure")))
    ExtensionBundle(name,UUID_VALUE,v"0.1.0",contributions;description="Lifecycle fixture")
end
end

function extension_error_code(f)
    try;f();nothing;catch error;error isa ShenScopeError ? error.code : rethrow();end
end
