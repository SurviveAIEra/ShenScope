module ShenScopeLifecycleExample
using ShenScope, UUIDs
import ShenScope: tool_name,tool_schema,tool_description,execute
struct EchoTool <: AbstractTool end
tool_name(::EchoTool)="example_echo"
tool_description(::EchoTool)="Return a bounded input from an independently installed Julia package"
tool_schema(::EchoTool)=ShenScope.object_schema(Dict("text"=>ShenScope.string_schema(;max=128));required=["text"])
execute(::EchoTool,args::AbstractDict,ctx::RuntimeContext)=Dict("echo"=>args["text"],"package"=>"ShenScopeLifecycleExample")
function shenscope_extension_bundle()
    ExtensionBundle("installed_example",UUID("c4e77152-5e6f-480b-8a7a-9fc6f6d7f6f2"),v"0.1.0",
        [ExtensionContribution("echo",:tool,ctx->EchoTool())];description="Independent optional package fixture")
end
end
