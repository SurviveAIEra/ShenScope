using HTTP,Dates

@testset "Model retry policies reject terminal categories and unbounded configuration" begin
    @test ModelRetryPolicy(;max_retries=0).max_retries == 0
    for value in (-1,33,true,1.5)
        @test_throws ShenScopeError ModelRetryPolicy(;max_retries=value)
    end
    for value in (NaN,Inf,true,-1.0)
        @test_throws ShenScopeError ModelRetryPolicy(;initial_delay=value)
    end
    @test_throws ShenScopeError ModelRetryPolicy(;maximum_delay=0)
    @test_throws ShenScopeError ModelRetryPolicy(;jitter_ratio=1.1)
    @test_throws ShenScopeError ModelRetryPolicy(;retryable_codes=[:authentication])
    @test_throws ShenScopeError ShenScope.model_retry_policy_from_dict(Dict("unknown"=>true))
    policy = ShenScope.model_retry_policy_from_dict(Dict("max_retries"=>3,"retryable_codes"=>["server","server"]))
    @test policy.retryable_codes == (:server,) && policy.max_retries == 3
    @test policy.retryable_codes isa Tuple
    config = deepcopy(ShenScope.DEFAULT_CONFIG)
    config["provider"]["retry_policy"] = Dict("max_retries"=>4,"jitter_ratio"=>0.0)
    config["provider"]["circuit"] = Dict("failure_threshold"=>7,"cooldown"=>0.5)
    provider = ShenScope.provider_from_config(config)
    @test provider.runtime.retry_policy.max_retries == 4
    @test provider.runtime.circuit_policy.failure_threshold == 7
    @test ModelsTool(config).provider.runtime.retry_policy.max_retries == 4
    config["provider"]["retries"] = true
    @test_throws ShenScopeError ShenScope.provider_from_config(config)
    for values in ((;failure_threshold=0),(;enabled=1),(;cooldown=Inf),(;maximum_cooldown=0.1,cooldown=1.0),(;max_in_flight=65))
        @test_throws ShenScopeError ModelCircuitPolicy(;values...)
    end
end

@testset "Provider retry headers are bounded, time-aware and never expose raw headers" begin
    response = HTTP.Response(429,["retry-after-ms"=>"1500","Retry-After"=>"30","x-should-retry"=>"false"])
    advice = ShenScope.model_retry_advice(response;monotonic_time=10.0,wall_time=0.0)
    @test advice.minimum_delay == 1.5 && advice.server_retry === false && advice.delay_status == :valid
    response = HTTP.Response(503,["retry-after-ms"=>"invalid","Retry-After"=>"2.25"])
    @test ShenScope.model_retry_advice(response).minimum_delay == 2.25
    base = datetime2unix(DateTime(2000,1,1,0,0,0))
    @test ShenScope.model_retry_http_date("Sat, 01 Jan 2000 00:00:03 GMT";wall_time=base) == (3.0,:valid)
    @test ShenScope.model_retry_http_date("Sat, 01 Jan 2000 00:00:03 GMT";wall_time=base+4) == (0.0,:valid)
    @test ShenScope.model_retry_http_date("Mon, 01 Jan 2000 00:00:03 GMT";wall_time=base) == (nothing,:invalid)
    @test ShenScope.model_retry_http_date("Sat, 32 Jan 2000 00:00:03 GMT";wall_time=base) == (nothing,:invalid)
    response = HTTP.Response(503,["Retry-After"=>"Sat, 01 Jan 2000 00:00:03 GMT"])
    @test ShenScope.model_retry_advice(response;monotonic_time=0.0,wall_time=base).minimum_delay == 3.0
    for raw in ("-1","NaN","Inf","1e8","fixture\nheader","")
        @test ShenScope.model_retry_numeric_delay(raw)[2] == :invalid
    end
    @test ShenScope.model_retry_numeric_delay(repeat("9",129))[2] == :too_large
    @test ShenScope.model_retry_advice(HTTP.Response(503)).delay_status == :absent
    @test ShenScope.model_response_failure(HTTP.Response(401,["x-should-retry"=>"true"])).error.code == :authentication
    @test !ShenScope.model_response_failure(HTTP.Response(401,["x-should-retry"=>"true"])).error.retryable
    @test ShenScope.model_response_failure(HTTP.Response(409,["x-should-retry"=>"true"])).error.retryable
    @test !ShenScope.model_response_failure(HTTP.Response(400,["x-should-retry"=>"true"])).error.retryable
    @test ShenScope.model_response_failure(HTTP.Response(529)).error.retryable
    failure = ShenScope.model_response_failure(HTTP.Response(503,["Retry-After"=>"PRIVATE RETRY FIXTURE"]))
    @test !occursin("PRIVATE RETRY FIXTURE",sprint(showerror,failure))
end

@testset "Retry decisions preserve server floors, delivery and configured/deadline limits" begin
    policy = ModelRetryPolicy(;max_retries=3,initial_delay=0.5,maximum_delay=8.0,jitter_ratio=0.25)
    failure = ModelAttemptFailure(ShenScopeError(:rate_limit,"fixture",true),ModelRetryAdvice(nothing,0.0,nothing,:absent),429)
    for attempt in 0:2, sample in (0.0,0.5,1.0)
        decision = model_retry_decision(policy,failure,attempt;random_value=sample,now=0.0)
        base = 0.5*2^attempt
        @test decision.retry && base*0.75 <= decision.delay <= base*1.25
    end
    @test model_retry_decision(policy,failure,0;delivered=true).reason == :delivered
    @test model_retry_decision(policy,failure,3).reason == :attempt_limit
    @test model_retry_decision(policy,failure,0;remaining_seconds=0.1).reason == :shared_deadline
    declined = ModelAttemptFailure(failure.error,ModelRetryAdvice(nothing,0.0,false,:absent),429)
    @test model_retry_decision(policy,declined,0).reason == :server_declined
    timed = ModelAttemptFailure(failure.error,ModelRetryAdvice(7.0,10.0,true,:valid),429)
    @test model_retry_decision(policy,timed,0;now=12.0,random_value=0.5).delay == 5.0
    @test model_retry_decision(policy,timed,0;now=18.0,random_value=0.5).delay == 0.5
    long = ModelAttemptFailure(failure.error,ModelRetryAdvice(9.0,0.0,nothing,:valid),429)
    @test model_retry_decision(policy,long,0;now=0.0).reason == :server_wait_exceeds_policy
    unlimited = ModelAttemptFailure(failure.error,ModelRetryAdvice(nothing,0.0,nothing,:too_large),429)
    @test !model_retry_decision(policy,unlimited,0).retry
    for code in (:cancelled,:budget,:permission,:authentication,:context_overflow,:protocol)
        terminal = ModelAttemptFailure(ShenScopeError(code,"fixture",true),ModelRetryAdvice(),nothing)
        @test model_retry_decision(policy,terminal,0).reason == :terminal
    end
    @test_throws ArgumentError model_retry_decision(policy,failure,0;random_value=NaN)
    @test_throws ArgumentError model_retry_decision(policy,failure,0;remaining_seconds=true)
end
