function model_health_snapshot(provider::HTTPProvider,ctx::RuntimeContext;credentials=nothing)
    catalog_read_authorize!(ctx)
    key = credentials === nothing ? CredentialSnapshot(provider.credential_lookup(provider.config.key_env)) : credentials
    key isa CredentialSnapshot || throw(ArgumentError("Model health credentials must be a captured snapshot"))
    model_health_read(provider,ctx,key)
end

function model_health_read(provider::HTTPProvider,ctx::RuntimeContext,key::CredentialSnapshot)
    manager = provider.runtime.circuits;scope = model_circuit_key(provider,key,ctx)
    health = lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Model circuit manager is closed"))
        entry = get(manager.entries,scope,nothing)
        entry === nothing ? model_circuit_empty_view(provider.runtime.circuit_policy) : model_circuit_view(entry,model_circuit_clock(manager))
    end
    catalog_read_checkpoint(ctx)
    merge(health,Dict("source_id"=>scope[3],"provider"=>provider_name(provider),
        "scope"=>"workspace/state/provider/credential","retry_policy"=>model_retry_policy_dict(provider.runtime.retry_policy),
        "availability_is_observation"=>true,"reset_is_health_probe"=>false))
end

function reset_model_health!(provider::HTTPProvider,ctx::RuntimeContext;expected_revision,clear=false)
    expected_revision isa Integer && !(expected_revision isa Bool) && 0 <= expected_revision <= typemax(Int) ||
        throw(ShenScopeError(:arguments,"Model health reset requires a nonnegative expected revision"))
    clear isa Bool || throw(ShenScopeError(:arguments,"Model health clear option must be Boolean"))
    catalog_read_authorize!(ctx)
    credentials = CredentialSnapshot(provider.credential_lookup(provider.config.key_env))
    manager = provider.runtime.circuits;scope = model_circuit_key(provider,credentials,ctx)
    host = String(validate_endpoint(provider.config.endpoint).host)
    authorize!(ctx,:network,"models.health.reset",host;
        reason="Clear provider cooldown and allow future inference; this reset does not perform a network probe")
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Model circuit manager is closed"))
        permission_decision(ctx.permissions,PermissionRequest("model-health-reset",:network,"models.health.reset",host,"Reset health")) != Deny ||
            throw(ShenScopeError(:permission,"Model health reset network permission was revoked"))
        entry = get(manager.entries,scope,nothing)
        revision = entry === nothing ? 0 : entry.revision
        revision == expected_revision || throw(ShenScopeError(:conflict,"Model health changed; refresh before resetting"))
        if entry !== nothing
            isempty(entry.leases) || throw(ShenScopeError(:conflict,"Finish model inference before resetting health"))
            catalog_read_checkpoint(ctx)
            if clear
                delete!(manager.entries,scope)
            else
                entry.revision < typemax(Int) && entry.epoch < typemax(Int) ||
                    throw(ShenScopeError(:capacity,"Clear idle health history to recover exhausted circuit versions"))
                entry.state = entry.policy.enabled ? :closed : :disabled
                entry.consecutive_failures = 0;entry.last_failure_time = nothing
                entry.last_failure_code = nothing;entry.open_until = 0.0;entry.cooldown = entry.policy.cooldown
                entry.last_outcome = nothing;entry.epoch = model_circuit_version_increment(entry.epoch)
                entry.last_activity = model_circuit_clock(manager);model_circuit_record!(manager,entry,:manual_reset)
            end
        end
    end
    merge(model_health_read(provider,ctx,credentials),Dict("reset"=>true,"cleared"=>clear))
end

function invalidate_model_circuits!(manager::ModelCircuitManager)
    lock(manager.mutex) do
        # Existing leases continue to occupy their old entry until their owner
        # settles. Changing credentials creates a distinct scope for new work.
        for (key,entry) in collect(manager.entries)
            isempty(entry.leases) && delete!(manager.entries,key)
        end
    end
    nothing
end

function close_model_circuits!(manager::ModelCircuitManager)
    lock(manager.mutex) do;manager.closed = true;empty!(manager.entries);end
    nothing
end
