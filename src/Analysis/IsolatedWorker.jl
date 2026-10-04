function compute_worker_failure(identifier, source_hash, stage, message)
    Dict("protocol" => COMPUTE_PROTOCOL_VERSION, "kind" => "result", "id" => identifier,
        "source_sha256" => source_hash, "error" => Dict("stage" => stage, "message" => message))
end

function compute_worker_evaluate(request::AbstractDict, limits::ComputeLimits)
    allowed = Set(["protocol", "id", "source", "source_sha256", "inputs"])
    Set(keys(request)) == allowed && request["protocol"] === COMPUTE_PROTOCOL_VERSION ||
        throw(ShenScopeError(:compute_protocol, "Invalid compute request"))
    identifier = request["id"]
    identifier isa AbstractString && 1 <= ncodeunits(identifier) <= 128 ||
        throw(ShenScopeError(:compute_protocol, "Invalid compute request ID"))
    source = compute_source(request["source"], limits)
    source_hash = digest(source)
    source_hash == request["source_sha256"] || throw(ShenScopeError(:compute_protocol, "Compute source digest differs"))
    inputs = request["inputs"]
    inputs isa AbstractVector && 1 <= length(inputs) <= limits.max_tests + 1 ||
        throw(ShenScopeError(:compute_protocol, "Invalid compute input count"))
    all(input -> input isa AbstractDict && Set(keys(input)) == Set(["data", "request"]) &&
        input["data"] isa AbstractDict && input["request"] isa AbstractDict, inputs) ||
        throw(ShenScopeError(:compute_protocol, "Invalid compute input shape"))
    stage = "source"
    try
        started = time_ns()
        expression = Meta.parseall(source; filename="analyzer-" * source_hash[1:16] * ".jl")
        candidate = Module(gensym(:ShenScopeAnalyzer))
        Core.eval(candidate, expression)
        compile_seconds = (time_ns() - started) / 1e9
        stage = "contract"
        isdefined(candidate, :analyze) && isdefined(candidate, :selftest) ||
            return compute_worker_failure(identifier, source_hash, stage, "Define analyze(data, request) and selftest()")
        analyzer = getfield(candidate, :analyze)
        tester = getfield(candidate, :selftest)
        analyzer isa Function && tester isa Function &&
            Base.invokelatest(hasmethod, analyzer, Tuple{Dict{String,Any},Dict{String,Any}}) &&
            Base.invokelatest(hasmethod, tester, Tuple{}) ||
            return compute_worker_failure(identifier, source_hash, stage, "Analyzer methods do not satisfy the data contract")
        stage = "selftest"
        Base.invokelatest(tester) === true ||
            return compute_worker_failure(identifier, source_hash, stage, "selftest() must return true")
        stage = "analyze"
        started = time_ns()
        results = Dict{String,Any}[]
        for input in inputs
            result = Base.invokelatest(analyzer, input["data"], input["request"])
            result isa AbstractDict || return compute_worker_failure(identifier, source_hash, stage, "analyze() must return a dictionary")
            # Round-trip here bounds the wire type. Parent validation remains
            # authoritative: generated code can modify anything in this child.
            text = canonical(result)
            ncodeunits(text) <= limits.output_bytes ||
                return compute_worker_failure(identifier, source_hash, "capacity", "Analyzer result exceeds output capacity")
            push!(results, bounded_json_object(text; maximum=limits.output_bytes,
                max_depth=24, max_nodes=100_000, error_code=:analysis))
        end
        Dict("protocol" => COMPUTE_PROTOCOL_VERSION, "kind" => "result", "id" => identifier,
            "source_sha256" => source_hash, "selftest" => true, "results" => results,
            "metrics" => Dict("compile_seconds" => compile_seconds, "analyze_seconds" => (time_ns() - started) / 1e9))
    catch
        # Raw exceptions/backtraces can reveal bootstrap paths or input values.
        compute_worker_failure(identifier, source_hash, stage, "Analyzer raised an exception")
    end
end

function compute_worker_warmup(limits::ComputeLimits)
    source = "analyze(data, request) = Dict(\"value\" => sum(data[\"values\"]))\nselftest() = true"
    request = Dict("protocol" => COMPUTE_PROTOCOL_VERSION, "id" => "warmup", "source" => source,
        "source_sha256" => digest(source), "inputs" => [Dict("data" => Dict("values" => [1, 2]), "request" => Dict())])
    compute_worker_evaluate(request, limits)
    bounded_json_object(canonical(request); maximum=limits.input_bytes)
    canonical(compute_worker_failure("warmup", digest(source), "source", "warmup"))
    flush(stdout)
    nothing
end

function compute_worker_main(limits::ComputeLimits)
    status = 1
    try
        get(ENV, "SHENSCOPE_ISOLATED_CHILD", "") == "1" || return 1
        # Nothing supplied by the caller is evaluated during trusted bootstrap.
        # Existing package caches are read only before the filter is installed.
        compute_worker_warmup(limits)
        compute_apply_resource_limits(limits)
        profile = compute_install_seccomp()
        ready = Dict("protocol" => COMPUTE_PROTOCOL_VERSION, "kind" => "ready", "pid" => getpid(),
            "sandbox" => profile, "limits" => compute_limits_dict(limits))
        println(stdout, canonical(ready)); flush(stdout)
        raw = bounded_record(stdin, limits.input_bytes)
        request = compute_frame(raw, limits.input_bytes)
        result = compute_worker_evaluate(request, limits)
        text = canonical(result)
        if ncodeunits(text) + 1 > limits.output_bytes
            text = canonical(compute_worker_failure(request["id"], request["source_sha256"],
                "capacity", "Combined analyzer results exceed output capacity"))
        end
        println(stdout, text); flush(stdout)
        status = 0
    catch
        # Bootstrap failure must never announce ready. After ready, an absent
        # result is a protocol failure and the parent retires this process.
        status = 1
    end
    # Julia shutdown hooks may read/write files. The compute child owns no
    # persisted state, so terminate directly after flushing the protocol pipe.
    ccall(:_exit, Cvoid, (Cint,), status)
    status
end
