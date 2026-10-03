function settle_model_failure!(session::Session, ctx::RuntimeContext, lease::String, delivery::ModelDelivery)
    active = lock(ctx.budget.mutex) do; haskey(ctx.budget.reservations, lease); end
    active || return
    if delivery.usage === nothing
        release!(ctx.budget, lease)
    else
        settle!(ctx.budget, lease, delivery.usage); record_usage!(session, delivery.usage)
    end
end

function request_with_context_recovery!(provider::AbstractModelProvider, session::Session, ctx::RuntimeContext;
        tools, schemas, max_output, options, context_bytes, hook_context)
    manager = context_manager_for_tools(tools)
    byte_limit = min(context_bytes, manager.config.max_request_bytes)
    token_limit = nothing
    force = false
    previous_measure = nothing
    previous_digest = nothing
    for attempt in 0:manager.config.recovery_attempts
        check_cancelled(ctx.cancellation)
        request, projection = prepare_context!(provider, session, ctx; manager, tools, schemas, max_output,
            options, hook_context, byte_limit, token_limit, force)
        measure = projection.measure
        request_hash = digest(canonical(Dict("messages" => message_dict.(request.messages), "tools" => request.tools,
            "options" => request.options, "max_output" => request.max_output)))
        if previous_measure !== nothing
            request_hash != previous_digest && measure.estimated_tokens < previous_measure.estimated_tokens &&
                measure.wire_bytes < previous_measure.wire_bytes ||
                throw(ShenScopeError(:context_overflow, "Context recovery could not produce a smaller request"))
        end
        validate_request(provider, request)
        prices = provider isa HTTPProvider ? (provider.config.input_price, provider.config.output_price) : (0.0, 0.0)
        lease = reserve!(ctx.budget, measure.estimated_tokens + max_output,
            (measure.estimated_tokens * prices[1] + max_output * prices[2]) / 1_000_000)
        delivery = ModelDelivery()
        try
            emit!(ctx, :model_request, Dict("provider" => provider_name(provider),
                "estimated_input_tokens" => measure.estimated_tokens, "context_attempt" => attempt,
                "request_sha256" => request_hash))
            result = stream_chat(provider, request, model_delivery_sink(delivery, ctx), ctx)
            settle!(ctx.budget, lease, result.usage); record_usage!(session, result.usage)
            return result
        catch error
            settle_model_failure!(session, ctx, lease, delivery)
            if error isa ShenScopeError && error.code == :context_overflow && !delivery.delivered &&
                    attempt < manager.config.recovery_attempts && manager.config.auto_compact
                emit!(ctx, :context_recovery, Dict("attempt" => attempt + 1, "code" => "context_overflow",
                    "prior_estimated_tokens" => measure.estimated_tokens, "prior_wire_bytes" => measure.wire_bytes,
                    "delivery_started" => false))
                previous_measure = measure; previous_digest = request_hash
                byte_limit = max(2048, min(byte_limit, floor(Int, max(measure.envelope_bytes, measure.wire_bytes) * 0.65)))
                token_limit = max(1, floor(Int, measure.estimated_tokens * 0.65))
                force = true
            else
                record_interrupted_model!(session, delivery, error)
                rethrow()
            end
        finally
            save_budget!(session, ctx)
        end
    end
    throw(ShenScopeError(:context_overflow, "Context recovery attempts exhausted"))
end
