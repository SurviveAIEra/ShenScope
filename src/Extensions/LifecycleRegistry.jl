function extension_scope!(registry::ExtensionRegistry,ctx::RuntimeContext)
    lock(registry.mutex) do
        registry.closed && throw(ShenScopeError(:extension_closed,"Extension registry is closed"))
        registry.root===nothing && (registry.root=ctx.root)
        registry.root==ctx.root || throw(ShenScopeError(:permission,"Extension registry belongs to another workspace"))
    end
end

function extension_bundle_copy(bundle::ExtensionBundle)
    # Copy collections without cloning function captures or resources.
    ExtensionBundle(bundle.name,bundle.package_uuid,bundle.version,copy(bundle.contributions);
        minimum_core=bundle.minimum_core,maximum_core=bundle.maximum_core,description=bundle.description)
end

function register_extension!(registry::ExtensionRegistry,bundle::ExtensionBundle,ctx::RuntimeContext;source=Dict{String,Any}(),authorized=false)
    extension_scope!(registry,ctx)
    bundle.minimum_core<=VERSION<bundle.maximum_core || throw(ShenScopeError(:extension_compatibility,"Extension does not support this Core version"))
    authorized || authorize!(ctx,:dynamic,"extension.lifecycle",extension_target(bundle);reason="Register a trusted loaded Julia extension")
    extension_checkpoint(ctx;target=extension_target(bundle),dynamic=true)
    retained=extension_bundle_copy(bundle)
    source isa AbstractDict && ncodeunits(canonical(source))<=16384 || throw(ShenScopeError(:capacity,"Extension source receipt exceeds capacity"))
    lock(registry.mutex) do
        haskey(registry.records,bundle.name) && throw(ShenScopeError(:conflict,"Extension is already registered"))
        length(registry.records)<EXTENSION_MAX_PACKAGES || throw(ShenScopeError(:capacity,"Extension registry package limit reached"))
        sum(length(value.bundle.contributions) for value in values(registry.records);init=0)+length(bundle.contributions)<=EXTENSION_MAX_CONTRIBUTIONS ||
            throw(ShenScopeError(:capacity,"Extension registry contribution limit reached"))
        registry.records[bundle.name]=ExtensionRecord(retained,:inactive,0,Dict{String,Any}(),Dict{String,Int}(),
            Dict{String,Dict{String,Any}}(),deepcopy(Dict{String,Any}(source)),nothing,0,nothing)
        registry.revision+=1
    end
    extension_inspect(registry,bundle.name,ctx)
end

function extension_record(registry::ExtensionRegistry,name::AbstractString)
    extension_identifier(name)
    get(registry.records,String(name),nothing)===nothing && throw(ShenScopeError(:extension,"Extension is not registered"))
    registry.records[String(name)]
end

function extension_record_view(record::ExtensionRecord)
    bundle=record.bundle
    Dict("name"=>bundle.name,"package_uuid"=>string(bundle.package_uuid),"version"=>string(bundle.version),
        "core_compatibility"=>Dict("minimum_inclusive"=>string(bundle.minimum_core),"maximum_exclusive"=>string(bundle.maximum_core)),
        "description"=>bundle.description,"phase"=>String(record.phase),"generation"=>record.generation,
        "active_calls"=>length(record.leases),"source"=>deepcopy(record.source),
        "contributions"=>[Dict("name"=>item.name,"kind"=>String(item.kind),
            "active"=>haskey(record.instances,item.name),"contract"=>haskey(record.contracts,item.name) ?
                Dict(key=>deepcopy(value) for (key,value) in record.contracts[item.name] if key!="reviewed_schema") : nothing) for item in bundle.contributions],
        "failure_stage"=>record.failure_stage===nothing ? nothing : String(record.failure_stage),
        "cleanup_failures"=>record.cleanup_failures,"julia_methods_unloaded"=>false,
        "isolation"=>"trusted_in_process","persistent_configuration"=>false)
end

function extension_inspect(registry::ExtensionRegistry,name::AbstractString,ctx::RuntimeContext)
    extension_scope!(registry,ctx);authorize!(ctx,:read,"extension.inventory",ctx.root)
    extension_checkpoint(ctx;target=ctx.root,read=true)
    lock(registry.mutex) do;merge(extension_record_view(extension_record(registry,name)),Dict("registry_id"=>registry.id));end
end
function extension_list(registry::ExtensionRegistry,ctx::RuntimeContext)
    extension_scope!(registry,ctx);authorize!(ctx,:read,"extension.inventory",ctx.root)
    extension_checkpoint(ctx;target=ctx.root,read=true)
    lock(registry.mutex) do
        Dict("registry_id"=>registry.id,"revision"=>registry.revision,"extensions"=>[extension_record_view(registry.records[name]) for name in sort!(collect(keys(registry.records)))],
            "automatic_installation"=>false,"automatic_loading"=>false,"module_unloading_supported"=>false)
    end
end

function unregister_extension!(registry::ExtensionRegistry,name::AbstractString,ctx::RuntimeContext;accept_cleanup_failure=false)
    extension_scope!(registry,ctx)
    target=lock(registry.mutex) do;extension_target(extension_record(registry,name).bundle);end
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Remove inactive extension registration; Julia methods remain loaded")
    extension_checkpoint(ctx;target,dynamic=true)
    lock(registry.mutex) do
        record=extension_record(registry,name)
        record.phase in (:inactive,:quarantined) && isempty(record.leases) || throw(ShenScopeError(:extension_busy,"Deactivate this extension before removing its registration"))
        record.cleanup_failures==0 || accept_cleanup_failure || throw(ShenScopeError(:extension_cleanup,"Extension cleanup failed; explicit acknowledgement is required to forget the registration"))
        delete!(registry.records,String(name));registry.revision+=1
        Dict("name"=>String(name),"removed"=>true,"julia_methods_unloaded"=>false,"cleanup_failures"=>record.cleanup_failures)
    end
end
