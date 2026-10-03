@enum WorkStatus begin
    WorkPending
    WorkReady
    WorkRunning
    WorkRetryWaiting
    WorkSucceeded
    WorkFailed
    WorkCancelled
    WorkBlocked
    WorkUncertain
end

const WORK_STATUS_NAMES = Dict(
    WorkPending => "pending", WorkReady => "ready", WorkRunning => "running",
    WorkRetryWaiting => "retry_waiting", WorkSucceeded => "succeeded",
    WorkFailed => "failed", WorkCancelled => "cancelled", WorkBlocked => "blocked",
    WorkUncertain => "uncertain")
const WORK_TERMINAL_STATUSES = Set([WorkSucceeded, WorkFailed, WorkCancelled, WorkBlocked])
const WORK_KINDS = Set([:tool, :test, :index, :analysis, :model])
const MAX_WORKFLOW_TASKS = 2048
const MAX_WORK_ARGUMENT_BYTES = 128 * 1024
const MAX_WORKFLOW_JOURNAL_BYTES = 128 * 1024 * 1024

function work_status(name::AbstractString)
    for (status, label) in WORK_STATUS_NAMES
        label == name && return status
    end
    throw(ShenScopeError(:tasks, "Unknown task status"))
end

Base.@kwdef struct WorkRetryPolicy
    max_attempts::Int = 1
    initial_delay::Float64 = 1.0
    maximum_delay::Float64 = 60.0
    multiplier::Float64 = 2.0
    jitter_fraction::Float64 = 0.1
end

function validate_work_retry(policy::WorkRetryPolicy)
    1 <= policy.max_attempts <= 32 || throw(ShenScopeError(:tasks, "Attempt limit must be between 1 and 32"))
    all(isfinite, (policy.initial_delay, policy.maximum_delay, policy.multiplier, policy.jitter_fraction)) ||
        throw(ShenScopeError(:tasks, "Retry policy values must be finite"))
    0 <= policy.initial_delay <= policy.maximum_delay <= 3600 ||
        throw(ShenScopeError(:tasks, "Invalid retry delays"))
    1 <= policy.multiplier <= 10 && 0 <= policy.jitter_fraction <= 0.5 ||
        throw(ShenScopeError(:tasks, "Invalid retry multiplier or jitter"))
    policy
end

function retry_policy_dict(policy::WorkRetryPolicy)
    Dict("max_attempts" => policy.max_attempts, "initial_delay" => policy.initial_delay,
        "maximum_delay" => policy.maximum_delay, "multiplier" => policy.multiplier,
        "jitter_fraction" => policy.jitter_fraction)
end

function retry_policy_from(value::AbstractDict)
    allowed = Set(["max_attempts", "initial_delay", "maximum_delay", "multiplier", "jitter_fraction"])
    all(key -> key in allowed, keys(value)) || throw(ShenScopeError(:tasks, "Unknown retry policy field"))
    attempts = get(value, "max_attempts", 1)
    attempts isa Integer && !(attempts isa Bool) && 1 <= attempts <= 32 || throw(ShenScopeError(:tasks, "Invalid retry attempt limit"))
    for key in ("initial_delay", "maximum_delay", "multiplier", "jitter_fraction")
        haskey(value, key) || continue
        value[key] isa Real && !(value[key] isa Bool) && isfinite(value[key]) || throw(ShenScopeError(:tasks, "Invalid retry numeric field"))
    end
    policy = WorkRetryPolicy(;
        max_attempts = get(value, "max_attempts", 1),
        initial_delay = get(value, "initial_delay", 1.0),
        maximum_delay = get(value, "maximum_delay", 60.0),
        multiplier = get(value, "multiplier", 2.0),
        jitter_fraction = get(value, "jitter_fraction", 0.1))
    validate_work_retry(policy)
end

function work_json_value(value; depth = 0, counter = Ref(0), max_string_bytes = MAX_WORK_ARGUMENT_BYTES, credentials = false)
    depth <= 32 || throw(ShenScopeError(:tasks, "Task JSON nesting exceeds limit"))
    counter[] += 1
    counter[] <= 20000 || throw(ShenScopeError(:tasks, "Task JSON item count exceeds limit"))
    if value isa AbstractDict
        for (key, child) in value
            key isa AbstractString && ncodeunits(key) <= 256 ||
                throw(ShenScopeError(:tasks, "Task JSON keys must be bounded strings"))
            !credentials && lowercase(key) in ("api_key", "authorization", "password", "secret") &&
                throw(ShenScopeError(:tasks, "Task definitions cannot contain credential fields"))
            work_json_value(child; depth = depth + 1, counter, max_string_bytes, credentials)
        end
    elseif value isa AbstractVector
        for child in value
            work_json_value(child; depth = depth + 1, counter, max_string_bytes, credentials)
        end
    elseif value isa AbstractString
        isvalid(value) && ncodeunits(value) <= max_string_bytes ||
            throw(ShenScopeError(:tasks, "Task string exceeds limits"))
    elseif value isa AbstractFloat
        isfinite(value) || throw(ShenScopeError(:tasks, "Task numbers must be finite"))
    elseif !(value === nothing || value isa Bool || value isa Integer)
        throw(ShenScopeError(:tasks, "Task definitions require JSON values"))
    end
    value
end

function work_replay_safe(kind::Symbol, operation::String, arguments::AbstractDict)
    kind == :analysis && return operation in ("impact", "test_selection", "architecture")
    kind == :tool || return false
    operation in ("read", "search") && return true
    operation == "diagnostics" && return get(arguments, "action", "") in ("contracts", "ambiguities", "targets")
    operation == "memory" && return get(arguments, "action", "") in ("get", "search", "history", "export")
    operation == "project" && return get(arguments, "action", "") in ("status", "search", "impact", "test_selection", "architecture")
    operation == "git" && return get(arguments, "action", "") in ("status", "diff", "log")
    false
end

struct WorkSpec
    id::String
    title::String
    kind::Symbol
    operation::String
    arguments::Dict{String,Any}
    dependencies::Vector{String}
    priority::Int
    retry::WorkRetryPolicy
    safe_retry::Bool
    timeout::Float64
    deduplication_key::String
end

function WorkSpec(id::AbstractString, kind::Symbol, operation::AbstractString, arguments::AbstractDict;
        title = id, dependencies = String[], priority = 0, retry = WorkRetryPolicy(),
        safe_retry = false, timeout = 300.0, deduplication_key = "")
    identifier = valid_id(id)
    kind in WORK_KINDS || throw(ShenScopeError(:tasks, "Unknown worker kind"))
    isempty(strip(operation)) && throw(ShenScopeError(:tasks, "Task operation is empty"))
    title isa AbstractString && isvalid(title) && !isempty(strip(title)) &&
        ncodeunits(operation) <= 128 && ncodeunits(title) <= 512 || throw(ShenScopeError(:tasks, "Task labels exceed limits"))
    dependencies isa AbstractVector && length(dependencies) <= 256 || throw(ShenScopeError(:tasks, "Dependency limit reached"))
    blockers = valid_id.(dependencies)
    length(unique(blockers)) == length(blockers) && !(identifier in blockers) ||
        throw(ShenScopeError(:tasks, "Duplicate or self dependency"))
    priority isa Integer && !(priority isa Bool) && -1000 <= priority <= 1000 ||
        throw(ShenScopeError(:tasks, "Invalid task priority"))
    safe_retry isa Bool || throw(ShenScopeError(:tasks, "Retry safety must be a boolean"))
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.1 <= timeout <= 3600 || throw(ShenScopeError(:tasks, "Invalid task timeout"))
    deduplication_key isa AbstractString && isvalid(deduplication_key) && ncodeunits(deduplication_key) <= 256 || throw(ShenScopeError(:tasks, "Deduplication key exceeds limit"))
    work_json_value(arguments)
    serialized = canonical(arguments)
    ncodeunits(serialized) <= MAX_WORK_ARGUMENT_BYTES || throw(ShenScopeError(:tasks, "Task arguments exceed limit"))
    safe_retry && !work_replay_safe(kind, String(operation), arguments) &&
        throw(ShenScopeError(:tasks, "This operation cannot be automatically replayed"))
    WorkSpec(identifier, String(title), kind, String(operation), parsejson(serialized), sort!(blockers),
        Int(priority), validate_work_retry(retry), safe_retry, Float64(timeout), String(deduplication_key))
end

function work_spec_dict(spec::WorkSpec)
    Dict("id" => spec.id, "title" => spec.title, "kind" => String(spec.kind),
        "operation" => spec.operation, "arguments" => spec.arguments,
        "dependencies" => spec.dependencies, "priority" => spec.priority,
        "retry" => retry_policy_dict(spec.retry), "safe_retry" => spec.safe_retry,
        "timeout" => spec.timeout, "deduplication_key" => spec.deduplication_key)
end

function work_spec_from(value::AbstractDict)
    required = ("id", "kind", "operation", "arguments")
    allowed = Set([required..., "title", "dependencies", "priority", "retry", "safe_retry", "timeout", "deduplication_key"])
    all(key -> key in allowed, keys(value)) && all(key -> haskey(value, key), required) ||
        throw(ShenScopeError(:tasks, "Invalid task definition fields"))
    all(key -> value[key] isa AbstractString, ("id", "kind", "operation")) && value["arguments"] isa AbstractDict ||
        throw(ShenScopeError(:tasks, "Invalid task definition types"))
    get(value, "retry", Dict()) isa AbstractDict || throw(ShenScopeError(:tasks, "Invalid retry policy"))
    WorkSpec(value["id"], Symbol(value["kind"]), value["operation"], value["arguments"];
        title = get(value, "title", value["id"]), dependencies = get(value, "dependencies", String[]),
        priority = get(value, "priority", 0), retry = retry_policy_from(get(value, "retry", Dict())),
        safe_retry = get(value, "safe_retry", false), timeout = get(value, "timeout", 300.0),
        deduplication_key = get(value, "deduplication_key", ""))
end

struct WorkLease
    worker::String
    token::String
    generation::Int
    issued_at::Float64
    expires_at::Float64
end

struct WorkFailure
    code::Symbol
    message::String
    retryable::Bool
    effects_uncertain::Bool
end

struct WorkReceipt
    execution_id::String
    attempt::Int
    phase::Symbol
    started_at::Float64
    finished_at::Union{Nothing,Float64}
    result_sha256::Union{Nothing,String}
    evidence::String
    hooks_started::Bool
    hooks_barrier::Bool
end

WorkReceipt(execution_id,attempt,phase,started_at,finished_at,result_sha256,evidence) =
    WorkReceipt(execution_id,attempt,phase,started_at,finished_at,result_sha256,evidence,false,false)
WorkReceipt(execution_id,attempt,phase,started_at,finished_at,result_sha256,evidence,hooks_started) =
    WorkReceipt(execution_id,attempt,phase,started_at,finished_at,result_sha256,evidence,hooks_started,hooks_started)

struct WorkRecord
    spec::WorkSpec
    status::WorkStatus
    version::Int
    attempts::Int
    not_before::Float64
    lease::Union{Nothing,WorkLease}
    result::Any
    failure::Union{Nothing,WorkFailure}
    receipts::Vector{WorkReceipt}
    cancel_requested::Bool
end

function WorkRecord(spec::WorkSpec)
    status = isempty(spec.dependencies) ? WorkReady : WorkPending
    WorkRecord(spec, status, 1, 0, 0.0, nothing, nothing, nothing, WorkReceipt[], false)
end

function replace_work(record::WorkRecord; status = record.status, attempts = record.attempts,
        not_before = record.not_before, lease = record.lease, result = record.result,
        failure = record.failure, receipts = record.receipts, cancel_requested = record.cancel_requested)
    WorkRecord(record.spec, status, record.version + 1, attempts, Float64(not_before), lease,
        result, failure, copy(receipts), cancel_requested)
end

function work_retry_delay(spec::WorkSpec, attempt::Int)
    validate_work_retry(spec.retry)
    exponent = clamp(attempt - 1, 0, 31)
    delay = min(spec.retry.maximum_delay, spec.retry.initial_delay * spec.retry.multiplier^exponent)
    seed = parse(UInt64, digest(spec.id * ":" * string(attempt))[1:16]; base = 16)
    fraction = Float64(seed) / Float64(typemax(UInt64))
    delay * (1 + spec.retry.jitter_fraction * (2fraction - 1))
end
