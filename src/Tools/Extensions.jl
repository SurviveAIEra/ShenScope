struct ExtensionsTool <: AbstractTool
    registry::ExtensionRegistry
    operations::OperationManager
end
ExtensionsTool()=ExtensionsTool(ExtensionRegistry(),OperationManager(;event_prefix="extensions",max_running=1))
tool_name(::ExtensionsTool)="extensions"
tool_description(::ExtensionsTool)="Inspect installed Julia packages; explicitly load and activate trusted optional contributions, invoke reviewed tools and drain them. Julia modules remain loaded and are not isolated."
execution_mode(::ExtensionsTool)=:exclusive
tool_schema(::ExtensionsTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["list","inspect","inspect_tool","inspect_package","load_package","load_optional","activate","deactivate","remove","invoke"]),
    "name"=>string_schema(;max=64),"package_name"=>string_schema(;max=64),"uuid"=>string_schema(;max=36),
    "version"=>string_schema(;max=64),"entry_sha256"=>string_schema(;max=64),"project_sha256"=>string_schema(;max=64),
    "contribution"=>string_schema(;max=64),"generation"=>integer_schema(1),"registry_id"=>string_schema(;max=36),
    "timeout"=>Dict("type"=>"number","minimum"=>0,"maximum"=>120),
    "accept_cleanup_failure"=>Dict("type"=>"boolean"),"arguments"=>Dict("type"=>"object","maxProperties"=>128));required=["action"])

function extension_argument(args,key)
    value=get(args,key,nothing)
    value isa AbstractString && !isempty(value) || throw(ShenScopeError(:arguments,"Extension argument "*key*" is required"))
    String(value)
end
function extension_package_uuid(args)
    try;UUID(extension_argument(args,"uuid"));catch;throw(ShenScopeError(:arguments,"A valid extension package UUID is required"));end
end
function extension_package_spec(args)
    version=try;VersionNumber(extension_argument(args,"version"));catch;throw(ShenScopeError(:arguments,"A valid extension package version is required"));end
    InstalledExtensionSpec(extension_argument(args,"package_name"),extension_package_uuid(args),version,
        extension_argument(args,"entry_sha256"),extension_argument(args,"project_sha256"))
end

function execute(tool::ExtensionsTool,args::AbstractDict,ctx::RuntimeContext)
    validate_schema(args,tool_schema(tool));action=args["action"];registry=tool.registry
    action=="list" && return merge(extension_list(registry,ctx),Dict("optional_extensions"=>optional_extension_status()))
    action=="inspect_package" && return installed_extension_receipt(extension_argument(args,"package_name"),extension_package_uuid(args),ctx)
    action=="load_package" && return load_installed_extension!(registry,extension_package_spec(args),ctx)
    name=extension_argument(args,"name")
    action=="inspect" && return extension_inspect(registry,name,ctx)
    if action=="inspect_tool"
        contribution=extension_argument(args,"contribution")
        extension_scope!(registry,ctx);authorize!(ctx,:read,"extension.inventory",ctx.root)
        extension_checkpoint(ctx;target=ctx.root,read=true)
        return lock(registry.mutex) do
            record=extension_record(registry,name);report=get(record.contracts,contribution,nothing)
            report!==nothing && haskey(report,"reviewed_schema") || throw(ShenScopeError(:extension_contract,"Requested contribution has no active reviewed tool schema"))
            Dict("name"=>name,"contribution"=>contribution,"generation"=>record.generation,"registry_id"=>registry.id,
                "schema"=>deepcopy(report["reviewed_schema"]),"phase"=>String(record.phase))
        end
    end
    action=="load_optional" && return register_optional_extension!(registry,name,ctx)
    action=="activate" && return activate_extension!(registry,name,ctx)
    action=="deactivate" && return deactivate_extension!(registry,name,ctx;timeout=get(args,"timeout",10.0))
    action=="remove" && return unregister_extension!(registry,name,ctx;accept_cleanup_failure=get(args,"accept_cleanup_failure",false))
    action=="invoke" || throw(ShenScopeError(:arguments,"Unknown extension action"))
    contribution=extension_argument(args,"contribution");generation=get(args,"generation",nothing)
    get(args,"registry_id",nothing)==registry.id || throw(ShenScopeError(:conflict,"Extension registry changed; inspect this tool again"))
    generation isa Integer && !(generation isa Bool) && generation>=1 || throw(ShenScopeError(:arguments,"Reviewed extension generation is required for invocation"))
    arguments=get(args,"arguments",nothing)
    arguments isa AbstractDict && length(arguments)<=128 || throw(ShenScopeError(:arguments,"Bounded extension tool arguments are required"))
    bounded_canonical_json(arguments;maximum=65536)
    value=with_extension_instance(registry,name,contribution,ctx;generation=Int(generation)) do instance
        instance isa AbstractTool || throw(ShenScopeError(:extension_contract,"Only tool contributions can be invoked through this control tool"))
        reviewed=lock(registry.mutex) do;deepcopy(extension_record(registry,name).contracts[contribution]["reviewed_schema"]);end
        canonical(Base.invokelatest(tool_schema,instance))==canonical(reviewed) || throw(ShenScopeError(:conflict,"Extension tool parameters changed after activation"))
        validate_schema(arguments,reviewed)
        Base.invokelatest(execute,instance,arguments,ctx)
    end
    bounded_canonical_json(value;maximum=2*1024^2)
    Dict("name"=>name,"contribution"=>contribution,"generation"=>generation,"registry_id"=>registry.id,"value"=>value,"isolation"=>"trusted_in_process")
end

function additional_tools(control::ExtensionsTool,ctx::RuntimeContext)
    active=lock(control.registry.mutex) do;any(record->record.phase==:active,values(control.registry.records));end
    active ? active_extension_tools(control.registry,ctx) : RegisteredExtensionTool[]
end

function extension_tool_snapshot(tools,ctx::RuntimeContext)
    result=collect(AbstractTool,tools)
    for control in tools
        control isa ExtensionsTool || continue
        append!(result,additional_tools(control,ctx))
    end
    length(unique(tool_name.(result)))==length(result) || throw(ShenScopeError(:conflict,"Registered extension tool name collides with the tool catalog"))
    result
end
