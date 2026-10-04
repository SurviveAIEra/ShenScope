function acquire_extension_lease!(registry::ExtensionRegistry,name::AbstractString,contribution::AbstractString,
        ctx::RuntimeContext;generation=nothing)
    extension_scope!(registry,ctx);extension_identifier(contribution)
    target=lock(registry.mutex) do;extension_target(extension_record(registry,name).bundle);end
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Invoke a trusted active Julia extension")
    extension_checkpoint(ctx;target,dynamic=true)
    lock(registry.mutex) do
        record=extension_record(registry,name)
        record.phase==:active || throw(ShenScopeError(:extension_busy,"Extension is not accepting new calls"))
        generation===nothing || generation==record.generation || throw(ShenScopeError(:conflict,"Extension generation changed"))
        haskey(record.instances,String(contribution)) || throw(ShenScopeError(:extension,"Unknown extension contribution"))
        length(record.leases)<256 || throw(ShenScopeError(:capacity,"Extension active-call limit reached"))
        token=string(uuid4());record.leases[token]=record.generation
        ExtensionLease(registry,String(name),String(contribution),record.generation,record.instances[String(contribution)],token)
    end
end
function release_extension_lease!(lease::ExtensionLease)
    lock(lease.registry.mutex) do
        record=get(lease.registry.records,lease.extension,nothing)
        record!==nothing && get(record.leases,lease.token,nothing)==lease.generation && delete!(record.leases,lease.token)
    end
    nothing
end
function with_extension_instance(f::Function,registry::ExtensionRegistry,name::AbstractString,
        contribution::AbstractString,ctx::RuntimeContext;generation=nothing)
    lease=acquire_extension_lease!(registry,name,contribution,ctx;generation)
    try
        result=Base.invokelatest(f,lease.instance)
        extension_checkpoint(ctx;target=extension_target(lock(registry.mutex) do;extension_record(registry,name).bundle;end),dynamic=true)
        result
    finally
        release_extension_lease!(lease)
    end
end

struct RegisteredExtensionTool <: AbstractTool
    registry::ExtensionRegistry
    extension::String
    contribution::String
    generation::Int
    name::String
    description::String
    schema::Dict{String,Any}
    mode::Symbol
end
tool_name(value::RegisteredExtensionTool)=value.name
tool_description(value::RegisteredExtensionTool)=value.description
tool_schema(value::RegisteredExtensionTool)=deepcopy(value.schema)
execution_mode(value::RegisteredExtensionTool)=value.mode
function execute(value::RegisteredExtensionTool,args::AbstractDict,ctx::RuntimeContext)
    with_extension_instance(value.registry,value.extension,value.contribution,ctx;generation=value.generation) do tool
        validate_schema(args,value.schema)
        # Recheck the reviewed parameters against a mutable live implementation.
        canonical(Base.invokelatest(tool_schema,tool))==canonical(value.schema) || throw(ShenScopeError(:conflict,"Extension tool parameter schema changed"))
        Base.invokelatest(execute,tool,args,ctx)
    end
end

function active_extension_tools(registry::ExtensionRegistry,ctx::RuntimeContext)
    extension_scope!(registry,ctx);authorize!(ctx,:read,"extension.inventory",ctx.root)
    candidates=lock(registry.mutex) do
        [(record.bundle.name,item.name,record.generation) for record in values(registry.records) if record.phase==:active
            for item in record.bundle.contributions if item.kind==:tool]
    end
    result=RegisteredExtensionTool[]
    for (name,contribution,generation) in sort!(candidates)
        wrapper=with_extension_instance(registry,name,contribution,ctx;generation) do tool
            generated="ext_"*digest(canonical([name,contribution]))[1:16]*"_"*first(contribution,43)
            generated in registry.reserved_names && throw(ShenScopeError(:conflict,"Extension tool name is reserved"))
            description=Base.invokelatest(tool_description,tool)
            description isa AbstractString && ncodeunits(description)<=4096 || throw(ShenScopeError(:extension_contract,"Invalid extension tool description"))
            reviewed=lock(registry.mutex) do;deepcopy(extension_record(registry,name).contracts[contribution]["reviewed_schema"]);end
            canonical(reviewed)==canonical(Base.invokelatest(tool_schema,tool)) || throw(ShenScopeError(:conflict,"Extension tool parameters changed after activation"))
            RegisteredExtensionTool(registry,name,contribution,generation,generated,String(description),
                Dict{String,Any}(reviewed),Base.invokelatest(execution_mode,tool))
        end
        push!(result,wrapper)
    end
    result
end
