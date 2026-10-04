function model_retry_decision(policy::ModelRetryPolicy,failure::ModelAttemptFailure,retries_used::Integer;
        delivered=false,remaining_seconds=Inf,random_value=rand(),now=model_monotonic_time())
    retries_used >= 0 && !(retries_used isa Bool) || throw(ArgumentError("Retry index must be nonnegative"))
    delivered isa Bool || throw(ArgumentError("Delivery marker must be Boolean"))
    random_value isa Real && isfinite(random_value) && 0 <= random_value <= 1 || throw(ArgumentError("Retry random sample is out of bounds"))
    now isa Real && !(now isa Bool) && isfinite(now) && now >= 0 &&
        remaining_seconds isa Real && !(remaining_seconds isa Bool) && !isnan(remaining_seconds) ||
        throw(ArgumentError("Invalid retry clock or deadline"))
    error = failure.error
    delivered && return ModelRetryDecision(false,0.0,:delivered)
    error.retryable && error.code in policy.retryable_codes || return ModelRetryDecision(false,0.0,:terminal)
    failure.advice.server_retry === false && return ModelRetryDecision(false,0.0,:server_declined)
    retries_used < policy.max_retries || return ModelRetryDecision(false,0.0,:attempt_limit)
    exponential = min(policy.maximum_delay,policy.initial_delay*2.0^min(retries_used,32))
    delay = min(policy.maximum_delay,exponential*(1-policy.jitter_ratio+2*policy.jitter_ratio*random_value))
    if policy.honor_server_delay
        failure.advice.delay_status == :too_large && return ModelRetryDecision(false,0.0,:server_wait_exceeds_policy)
        advised = failure.advice.minimum_delay
        if advised !== nothing
            elapsed = max(0.0,now-failure.advice.received_at)
            minimum = max(0.0,advised-elapsed)
            minimum <= policy.maximum_delay || return ModelRetryDecision(false,0.0,:server_wait_exceeds_policy)
            delay = max(delay,minimum)
        end
    end
    delay < remaining_seconds || return ModelRetryDecision(false,0.0,:shared_deadline)
    ModelRetryDecision(true,Float64(delay),:transient)
end

function model_retry_wait(ctx::RuntimeContext,delay::Real,checkpoint::Function;
        clock=model_monotonic_time,sleeper=sleep)
    !(delay isa Bool) && isfinite(delay) && 0 <= delay <= 300 || throw(ArgumentError("Invalid model retry wait"))
    deadline = clock()+delay
    while true
        check_cancelled(ctx.cancellation)
        lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
        checkpoint()
        remaining = deadline-clock()
        remaining > 0 || break
        sleeper(min(remaining,0.025))
    end
    nothing
end
