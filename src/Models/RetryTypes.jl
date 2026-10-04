const MODEL_TRANSIENT_FAILURES = Set([:transport,:timeout,:server,:rate_limit,:stream_interrupted])

struct ModelRetryPolicy
    max_retries::Int
    initial_delay::Float64
    maximum_delay::Float64
    jitter_ratio::Float64
    retryable_codes::Tuple{Vararg{Symbol}}
    honor_server_delay::Bool
end

function ModelRetryPolicy(;max_retries=2,initial_delay=0.25,maximum_delay=30.0,
        jitter_ratio=0.25,retryable_codes=MODEL_TRANSIENT_FAILURES,honor_server_delay=true)
    max_retries isa Integer && !(max_retries isa Bool) && 0 <= max_retries <= 32 ||
        throw(ShenScopeError(:config,"Model retry count must be an integer from zero through 32"))
    for (value,name) in ((initial_delay,"initial delay"),(maximum_delay,"maximum delay"),(jitter_ratio,"jitter ratio"))
        value isa Real && !(value isa Bool) && isfinite(value) ||
            throw(ShenScopeError(:config,"Model retry "*name*" must be finite"))
    end
    0 <= initial_delay <= maximum_delay <= 300 && maximum_delay > 0 && 0 <= jitter_ratio <= 1 ||
        throw(ShenScopeError(:config,"Invalid model retry timing bounds"))
    honor_server_delay isa Bool || throw(ShenScopeError(:config,"Server retry-delay policy must be Boolean"))
    retryable_codes isa Union{AbstractVector,AbstractSet,Tuple} && length(retryable_codes) <= length(MODEL_TRANSIENT_FAILURES) ||
        throw(ShenScopeError(:config,"Invalid model retry failure categories"))
    all(code->code isa Union{AbstractString,Symbol} && Symbol(code) in MODEL_TRANSIENT_FAILURES,retryable_codes) ||
        throw(ShenScopeError(:config,"Model retry policy contains a terminal or unknown failure category"))
    ModelRetryPolicy(Int(max_retries),Float64(initial_delay),Float64(maximum_delay),Float64(jitter_ratio),
        Tuple(sort!(unique(Symbol.(collect(retryable_codes))))),honor_server_delay)
end

function model_retry_policy_dict(policy::ModelRetryPolicy)
    Dict("max_retries"=>policy.max_retries,"initial_delay"=>policy.initial_delay,
        "maximum_delay"=>policy.maximum_delay,"jitter_ratio"=>policy.jitter_ratio,
        "retryable_codes"=>sort!(String.(collect(policy.retryable_codes))),"honor_server_delay"=>policy.honor_server_delay)
end

function model_retry_policy_from_dict(document;max_retries=2)
    document isa AbstractDict || throw(ShenScopeError(:config,"Model retry policy must be a table"))
    names = Set(["max_retries","initial_delay","maximum_delay","jitter_ratio","retryable_codes","honor_server_delay"])
    all(key->key in names,keys(document)) || throw(ShenScopeError(:config,"Unknown model retry policy option"))
    ModelRetryPolicy(;max_retries=get(document,"max_retries",max_retries),
        initial_delay=get(document,"initial_delay",0.25),maximum_delay=get(document,"maximum_delay",30.0),
        jitter_ratio=get(document,"jitter_ratio",0.25),retryable_codes=get(document,"retryable_codes",MODEL_TRANSIENT_FAILURES),
        honor_server_delay=get(document,"honor_server_delay",true))
end

struct ModelRetryAdvice
    minimum_delay::Union{Nothing,Float64}
    received_at::Float64
    server_retry::Union{Nothing,Bool}
    delay_status::Symbol
end
model_monotonic_time() = Float64(time_ns())/1e9
ModelRetryAdvice() = ModelRetryAdvice(nothing,model_monotonic_time(),nothing,:absent)

struct ModelAttemptFailure <: Exception
    error::ShenScopeError
    advice::ModelRetryAdvice
    status::Union{Nothing,Int}
end
Base.showerror(io::IO,error::ModelAttemptFailure) = showerror(io,error.error)
Base.show(io::IO,error::ModelAttemptFailure) = print(io,"ModelAttemptFailure(",error.error.code,")")

struct ModelRetryDecision
    retry::Bool
    delay::Float64
    reason::Symbol
end
