function contract_operations(::Type{T}) where {T<:AbstractEvidenceProjection}
    [contract_operation(:name,projection_name,Tuple{T},Tuple{AbstractEvidenceProjection}),
     contract_operation(:project,project_projection,Tuple{T,ProjectEvidenceSnapshot,RuntimeContext},
         Tuple{AbstractEvidenceProjection,ProjectEvidenceSnapshot,RuntimeContext})]
end

function extension_cleanup_instances(bundle::ExtensionBundle,instances::Dict{String,Any},ctx::RuntimeContext)
    failures=0
    for contribution in reverse(bundle.contributions)
        haskey(instances,contribution.name) || continue
        try
            Base.invokelatest(contribution.cleanup,instances[contribution.name],ctx)
        catch
            failures+=1
        end
    end
    failures
end

function activate_extension!(registry::ExtensionRegistry,name::AbstractString,ctx::RuntimeContext)
    extension_scope!(registry,ctx)
    bundle=lock(registry.mutex) do;extension_record(registry,name).bundle;end
    target=extension_target(bundle)
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Instantiate trusted extension contributions in the Core process")
    extension_checkpoint(ctx;target,dynamic=true)
    generation=lock(registry.mutex) do
        record=extension_record(registry,name)
        record.phase==:inactive || throw(ShenScopeError(:extension_busy,"Extension must be inactive before activation"))
        record.phase=:activating;registry.revision+=1;record.generation=registry.revision;record.generation
    end
    instances=Dict{String,Any}();contracts=Dict{String,Dict{String,Any}}();stage=:factory
    try
        for contribution in bundle.contributions
            extension_checkpoint(ctx;target,dynamic=true)
            value=Base.invokelatest(contribution.factory,ctx)
            # Retain before checking so malformed factories can still clean up.
            instances[contribution.name]=value;stage=:contract
            extension_kind(value)==contribution.kind || throw(ShenScopeError(:extension_contract,"Factory returned a different interface kind"))
            report=Base.invokelatest(contract_report,typeof(value))
            report["valid"] || throw(ShenScopeError(:extension_contract,"Factory interface is missing or ambiguous"))
            if value isa AbstractTool
                spec=Base.invokelatest(tool_schema,value)
                spec isa AbstractDict && get(spec,"type",nothing)=="object" && ncodeunits(canonical(spec))<=65536 || throw(ShenScopeError(:extension_contract,"Extension tool needs a bounded object parameter schema"))
                report["reviewed_schema"]=deepcopy(spec)
                mode=Base.invokelatest(execution_mode,value)
                mode in (:parallel,:exclusive) || throw(ShenScopeError(:extension_contract,"Extension tool has an invalid execution mode"))
            end
            contracts[contribution.name]=report;stage=:factory
        end
        extension_checkpoint(ctx;target,dynamic=true)
        lock(registry.mutex) do
            record=extension_record(registry,name)
            record.phase==:activating && record.generation==generation || throw(ShenScopeError(:conflict,"Extension activation changed"))
            record.instances=instances;record.contracts=contracts;record.phase=:active
            record.activation_context=ctx
            record.failure_stage=nothing;record.cleanup_failures=0;registry.revision+=1
        end
    catch error
        failures=extension_cleanup_instances(bundle,instances,ctx)
        lock(registry.mutex) do
            record=extension_record(registry,name)
            record.phase=:quarantined;record.failure_stage=stage;record.cleanup_failures=failures
            empty!(record.instances);registry.revision+=1
        end
        error isa ShenScopeError && rethrow()
        throw(ShenScopeError(:extension_factory,"Trusted extension activation failed; registration is quarantined"))
    end
    extension_inspect(registry,name,ctx)
end

function deactivate_extension!(registry::ExtensionRegistry,name::AbstractString,ctx::RuntimeContext;timeout=10.0)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0<=timeout<=120 || throw(ShenScopeError(:arguments,"Invalid extension drain timeout"))
    extension_scope!(registry,ctx)
    bundle=lock(registry.mutex) do;extension_record(registry,name).bundle;end
    target=extension_target(bundle)
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Drain trusted extension calls and close their resources")
    extension_checkpoint(ctx;target,dynamic=true)
    lock(registry.mutex) do
        record=extension_record(registry,name)
        record.phase in (:active,:draining) || throw(ShenScopeError(:extension_busy,"Extension is not active or draining"))
        if record.phase==:active;record.phase=:draining;registry.revision+=1;end
    end
    deadline=time()+Float64(timeout)
    while true
        extension_checkpoint(ctx;target,dynamic=true)
        ready=lock(registry.mutex) do;isempty(extension_record(registry,name).leases);end
        ready && break
        time()>=deadline && return extension_inspect(registry,name,ctx)
        cancellable_wait(ctx.cancellation,min(0.02,max(0,deadline-time())))
    end
    instances=lock(registry.mutex) do
        record=extension_record(registry,name)
        record.phase==:draining || throw(ShenScopeError(:extension_busy,"Another operation is closing this extension"))
        record.phase=:closing;registry.revision+=1;copy(record.instances)
    end
    failures=extension_cleanup_instances(bundle,instances,ctx)
    lock(registry.mutex) do
        record=extension_record(registry,name);empty!(record.instances);empty!(record.contracts)
        record.activation_context=nothing
        record.cleanup_failures=failures;record.failure_stage=failures==0 ? nothing : :cleanup
        record.phase=failures==0 ? :inactive : :quarantined;registry.revision+=1
    end
    extension_inspect(registry,name,ctx)
end

function close_extension_registry!(registry::ExtensionRegistry)
    names=lock(registry.mutex) do
        registry.closed=true
        for record in values(registry.records)
            record.phase in (:active,:activating) && (record.phase=:draining)
        end
        sort!(collect(keys(registry.records)))
    end
    pending=0;failures=0
    for name in names
        work=lock(registry.mutex) do
            record=registry.records[name]
            if record.phase!=:draining;return nothing;end
            if !isempty(record.leases) || record.activation_context===nothing
                pending+=1;return nothing
            end
            record.phase=:closing
            (record.bundle,copy(record.instances),record.activation_context)
        end
        work===nothing && continue
        count=extension_cleanup_instances(work...,)
        lock(registry.mutex) do
            record=registry.records[name];empty!(record.instances);empty!(record.contracts)
            record.activation_context=nothing;record.cleanup_failures=count
            record.failure_stage=count==0 ? nothing : :cleanup
            record.phase=count==0 ? :inactive : :quarantined;registry.revision+=1
        end
        failures+=count
    end
    Dict("closed"=>true,"pending_leased_or_activating_extensions"=>pending,"cleanup_failures"=>failures,
        "julia_methods_unloaded"=>false)
end
