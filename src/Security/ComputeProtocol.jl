const COMPUTE_PROTOCOL_VERSION = 1

function compute_source(source::AbstractString, limits::ComputeLimits)
    isvalid(source) && !isempty(strip(source)) && ncodeunits(source) <= limits.source_bytes &&
        !occursin('\0', source) || throw(ShenScopeError(:analysis, "Analyzer source is empty, invalid or exceeds capacity"))
    String(source)
end

function compute_frame(raw::AbstractString, maximum::Int)
    endswith(raw, "\n") || throw(ShenScopeError(:compute_protocol, "Compute frame is incomplete"))
    bounded_json_object(raw; maximum, max_depth=32, max_nodes=250_000,
        max_string_bytes=maximum, error_code=:compute_protocol)
end

function compute_ready_frame(value::AbstractDict, limits::ComputeLimits, process_id::Int)
    Set(keys(value)) == Set(["protocol", "kind", "pid", "sandbox", "limits"]) ||
        throw(ShenScopeError(:compute_protocol, "Compute bootstrap fields are invalid"))
    get(value, "protocol", nothing) === COMPUTE_PROTOCOL_VERSION && get(value, "kind", nothing) == "ready" &&
        get(value, "pid", nothing) == process_id && !(value["pid"] isa Bool) ||
        throw(ShenScopeError(:compute_protocol, "Compute bootstrap identity is invalid"))
    get(value, "limits", nothing) == compute_limits_dict(limits) ||
        throw(ShenScopeError(:compute_protocol, "Compute bootstrap resource limits differ"))
    profile = get(value, "sandbox", nothing)
    profile isa AbstractDict && get(profile, "backend", nothing) == "linux-seccomp-compute-v1" ||
        throw(ShenScopeError(:sandbox, "Compute bootstrap has no supported sandbox"))
    for key in ("enforced", "thread_synchronized", "no_new_privileges")
        get(profile, key, nothing) === true || throw(ShenScopeError(:sandbox, "Compute bootstrap did not enforce isolation"))
    end
    for key in ("filesystem_open", "filesystem_write", "network", "child_processes")
        get(profile, key, nothing) === false || throw(ShenScopeError(:sandbox, "Compute bootstrap permits forbidden access"))
    end
    deepcopy(profile)
end

function compute_result_frame(value::AbstractDict, identifier::String, source_sha256::String, count::Int)
    get(value, "protocol", nothing) === COMPUTE_PROTOCOL_VERSION && get(value, "kind", nothing) == "result" &&
        get(value, "id", nothing) == identifier && get(value, "source_sha256", nothing) == source_sha256 ||
        throw(ShenScopeError(:compute_protocol, "Compute response identity is invalid"))
    if haskey(value, "error")
        Set(keys(value)) == Set(["protocol", "kind", "id", "source_sha256", "error"]) ||
            throw(ShenScopeError(:compute_protocol, "Compute rejection fields are invalid"))
        fault = value["error"]
        fault isa AbstractDict && Set(keys(fault)) == Set(["stage", "message"]) &&
            get(fault, "stage", nothing) in ("source", "contract", "selftest", "analyze", "capacity") &&
            get(fault, "message", nothing) isa AbstractString && ncodeunits(fault["message"]) <= 1024 ||
            throw(ShenScopeError(:compute_protocol, "Compute rejection is malformed"))
        throw(ShenScopeError(:analysis, "Isolated analyzer failed at " * fault["stage"] * ": " * fault["message"]))
    end
    Set(keys(value)) == Set(["protocol", "kind", "id", "source_sha256", "selftest", "results", "metrics"]) ||
        throw(ShenScopeError(:compute_protocol, "Compute response fields are invalid"))
    value["selftest"] === true || throw(ShenScopeError(:analysis, "Analyzer selftest did not pass"))
    results = value["results"]
    results isa AbstractVector && length(results) == count && all(result -> result isa AbstractDict, results) ||
        throw(ShenScopeError(:compute_protocol, "Compute result count or type is invalid"))
    metrics = value["metrics"]
    metrics isa AbstractDict && Set(keys(metrics)) == Set(["compile_seconds", "analyze_seconds"]) ||
        throw(ShenScopeError(:compute_protocol, "Compute metrics are invalid"))
    all(item -> item isa Real && !(item isa Bool) && isfinite(item) && item >= 0, values(metrics)) ||
        throw(ShenScopeError(:compute_protocol, "Compute metrics are non-finite"))
    Dict("results" => deepcopy(results), "selftest" => true, "metrics" => deepcopy(metrics))
end
