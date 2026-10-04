struct ModelCircuitPolicy
    enabled::Bool
    failure_threshold::Int
    failure_window::Float64
    cooldown::Float64
    maximum_cooldown::Float64
    max_in_flight::Int
end

function ModelCircuitPolicy(;enabled=true,failure_threshold=3,failure_window=60.0,
        cooldown=30.0,maximum_cooldown=300.0,max_in_flight=16)
    enabled isa Bool || throw(ShenScopeError(:config,"Model circuit enabled option must be Boolean"))
    failure_threshold isa Integer && !(failure_threshold isa Bool) && 1 <= failure_threshold <= 1000 ||
        throw(ShenScopeError(:config,"Invalid model circuit failure threshold"))
    max_in_flight isa Integer && !(max_in_flight isa Bool) && 1 <= max_in_flight <= 64 ||
        throw(ShenScopeError(:config,"Invalid model circuit concurrency capacity"))
    all(value->value isa Real && !(value isa Bool) && isfinite(value),(failure_window,cooldown,maximum_cooldown)) &&
        0.05 <= failure_window <= 3600 && 0.05 <= cooldown <= maximum_cooldown <= 3600 ||
        throw(ShenScopeError(:config,"Invalid model circuit timing bounds"))
    ModelCircuitPolicy(enabled,Int(failure_threshold),Float64(failure_window),Float64(cooldown),Float64(maximum_cooldown),Int(max_in_flight))
end

function model_circuit_policy_dict(policy::ModelCircuitPolicy)
    Dict("enabled"=>policy.enabled,"failure_threshold"=>policy.failure_threshold,
        "failure_window"=>policy.failure_window,"cooldown"=>policy.cooldown,
        "maximum_cooldown"=>policy.maximum_cooldown,"max_in_flight"=>policy.max_in_flight)
end

function model_circuit_policy_from_dict(document)
    document isa AbstractDict || throw(ShenScopeError(:config,"Model circuit policy must be a table"))
    names = Set(String.(fieldnames(ModelCircuitPolicy)))
    all(key->key in names,keys(document)) || throw(ShenScopeError(:config,"Unknown model circuit policy option"))
    ModelCircuitPolicy(;Dict(Symbol(key)=>value for (key,value) in document)...)
end

const ModelCircuitKey = Tuple{String,String,String,String}

mutable struct ModelCircuitEntry
    policy::ModelCircuitPolicy
    state::Symbol
    revision::Int
    epoch::Int
    consecutive_failures::Int
    last_failure_time::Union{Nothing,Float64}
    last_failure_code::Union{Nothing,Symbol}
    open_until::Float64
    cooldown::Float64
    leases::Dict{String,Tuple{Int,Bool}}
    successes::Int
    failures::Int
    neutral_outcomes::Int
    last_outcome::Union{Nothing,Symbol}
    last_activity::Float64
    history::Vector{Dict{String,Any}}
end

mutable struct ModelCircuitManager
    entries::Dict{ModelCircuitKey,ModelCircuitEntry}
    mutex::ReentrantLock
    salt::String
    max_sources::Int
    max_history::Int
    max_leases::Int
    clock::Function
    closed::Bool
end

function ModelCircuitManager(;max_sources=64,max_history=32,max_leases=64,clock=model_monotonic_time)
    max_sources isa Integer && !(max_sources isa Bool) && 1 <= max_sources <= 1024 ||
        throw(ArgumentError("Invalid model circuit source capacity"))
    max_history isa Integer && !(max_history isa Bool) && 1 <= max_history <= 128 ||
        throw(ArgumentError("Invalid model circuit history capacity"))
    max_leases isa Integer && !(max_leases isa Bool) && 1 <= max_leases <= 1024 ||
        throw(ArgumentError("Invalid model circuit overall concurrency capacity"))
    ModelCircuitManager(Dict(),ReentrantLock(),string(uuid4()),Int(max_sources),Int(max_history),Int(max_leases),clock,false)
end
Base.show(io::IO,manager::ModelCircuitManager) = print(io,"ModelCircuitManager(bounded runtime state)")

struct ModelCircuitLease
    key::ModelCircuitKey
    id::String
    epoch::Int
    probe::Bool
end
Base.show(io::IO,lease::ModelCircuitLease) = print(io,"ModelCircuitLease(",lease.probe ? "probe" : "request",")")

struct ModelProviderRuntime
    retry_policy::ModelRetryPolicy
    circuit_policy::ModelCircuitPolicy
    circuits::ModelCircuitManager
end
function ModelProviderRuntime(;retry_policy=ModelRetryPolicy(),circuit_policy=ModelCircuitPolicy(),circuits=ModelCircuitManager())
    ModelProviderRuntime(deepcopy(retry_policy),circuit_policy,circuits)
end
Base.show(io::IO,runtime::ModelProviderRuntime) = print(io,"ModelProviderRuntime(retry and circuit policy)")
