function model_network_checkpoint(provider::HTTPProvider,prepared::PreparedRequest,ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    host = String(HTTP.URI(prepared.endpoint).host)
    permission_decision(ctx.permissions,PermissionRequest("model-network-current",:network,
        provider_name(provider),host,"Continue model inference")) != Deny ||
        throw(ShenScopeError(:permission,"Model inference network permission was revoked"))
    nothing
end

function model_remaining_seconds(ctx::RuntimeContext)
    lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
        ctx.budget.limits.max_seconds-(time_ns()-ctx.budget.started_ns)/1e9
    end
end

function model_health_event(ctx::RuntimeContext,source_id::String,settlement::AbstractDict)
    get(settlement,"settled",false) || return nothing
    health = settlement["health"]
    payload = Dict("source_id"=>source_id,"state"=>health["state"],"revision"=>health["revision"],
        "current_epoch"=>settlement["current_epoch"],"consecutive_failures"=>health["consecutive_failures"],
        "in_flight"=>health["in_flight"],"wait_seconds"=>health["wait_seconds"],"last_outcome"=>health["last_outcome"])
    # Completion of inference is independent of an observational health event.
    # Delivery sinks for model text/tools still fail visibly if disconnected.
    try emit!(ctx,:model_provider_health,payload) catch end
    nothing
end

function model_policy_event!(ctx::RuntimeContext,kind::Symbol,payload::AbstractDict)
    try
        emit!(ctx,kind,payload)
    catch cause
        cause isa ShenScopeError && rethrow()
        throw(ShenScopeError(:delivery,"Model policy event consumer failed",false))
    end
end

function model_stream_with_policy(provider::HTTPProvider,prepared::PreparedRequest,sink::Function,ctx::RuntimeContext)
    manager = provider.runtime.circuits
    policy = provider.runtime.retry_policy
    # Serialize once before retries, so caller mutations of nested options or
    # replay objects cannot change the body after the logical request starts.
    encoded_body = bounded_canonical_json(prepared.body;maximum=8*1024^2,max_depth=24,max_nodes=100_000)
    scope = model_circuit_key(provider,prepared.credentials,ctx)
    lease = acquire_model_circuit!(manager,scope,provider.runtime.circuit_policy)
    delivered = Ref(false)
    guarded = (kind,payload) -> begin
        kind in (:text_delta,:usage,:tool_call,:model_progress) && (delivered[] = true)
        try
            sink(kind,payload)
        catch cause
            cause isa ShenScopeError && rethrow()
            throw(ShenScopeError(:delivery,"Model output consumer failed",false))
        end
    end
    settled = false
    try
        retries_used = 0
        while true
            model_network_checkpoint(provider,prepared,ctx)
            try
                response = stream_attempt(provider,prepared,guarded,ctx;encoded_body)
                model_network_checkpoint(provider,prepared,ctx)
                settlement = settle_model_circuit!(manager,lease,:success)
                settled = true;model_health_event(ctx,scope[3],settlement)
                return response
            catch cause
                model_network_checkpoint(provider,prepared,ctx)
                failure = model_attempt_failure(cause)
                decision = model_retry_decision(policy,failure,retries_used;delivered=delivered[],
                    remaining_seconds=model_remaining_seconds(ctx))
                if !decision.retry
                    if failure.error.retryable && failure.error.code in MODEL_TRANSIENT_FAILURES && !delivered[]
                        model_policy_event!(ctx,:model_retry_suppressed,Dict("code"=>String(failure.error.code),
                            "reason"=>String(decision.reason),"retries_used"=>retries_used,
                            "maximum_retries"=>policy.max_retries))
                    end
                    throw(failure.error)
                end
                retries_used += 1
                model_policy_event!(ctx,:model_retry,Dict("attempt"=>retries_used,"code"=>String(failure.error.code),
                    "delay_seconds"=>decision.delay,"maximum_retries"=>policy.max_retries,
                    "server_advice_used"=>policy.honor_server_delay && failure.advice.minimum_delay !== nothing))
                model_retry_wait(ctx,decision.delay,()->model_network_checkpoint(provider,prepared,ctx))
            end
        end
    catch cause
        error = cause isa ShenScopeError ? cause : model_attempt_failure(cause).error
        outcome = error.retryable && error.code in MODEL_TRANSIENT_FAILURES ? :failure : :neutral
        observation = occursin(r"^[a-z][a-z0-9_]{0,63}$",String(error.code)) ? error.code : :internal
        settlement = settle_model_circuit!(manager,lease,outcome;code=observation)
        settled = true;model_health_event(ctx,scope[3],settlement)
        throw(error)
    finally
        settled || settle_model_circuit!(manager,lease,:neutral;code=:internal)
    end
end
