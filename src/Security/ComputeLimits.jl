struct ComputeLimits
    wall_seconds::Float64
    cpu_seconds::Int
    address_space_bytes::UInt64
    input_bytes::Int
    output_bytes::Int
    source_bytes::Int
    max_tests::Int
end

function ComputeLimits(; wall_seconds=60.0, cpu_seconds=30,
        address_space_bytes=8 * 1024^3, input_bytes=8 * 1024^2,
        output_bytes=1024^2, source_bytes=256 * 1024, max_tests=32)
    wall_seconds isa Real && !(wall_seconds isa Bool) && isfinite(wall_seconds) &&
        0.05 <= wall_seconds <= 600 || throw(ShenScopeError(:arguments, "Invalid compute wall limit"))
    for (name, value, minimum, maximum) in (("CPU", cpu_seconds, 1, 300),
            ("address space", address_space_bytes, 512 * 1024^2, 32 * 1024^3),
            ("input", input_bytes, 1024, 32 * 1024^2),
            ("output", output_bytes, 1024, 4 * 1024^2),
            ("source", source_bytes, 64, 1024^2), ("tests", max_tests, 1, 128))
        value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
            throw(ShenScopeError(:arguments, "Invalid compute " * name * " limit"))
    end
    ComputeLimits(Float64(wall_seconds), Int(cpu_seconds), UInt64(address_space_bytes),
        Int(input_bytes), Int(output_bytes), Int(source_bytes), Int(max_tests))
end

function compute_limits_dict(limits::ComputeLimits)
    Dict("wall_seconds" => limits.wall_seconds, "cpu_seconds" => limits.cpu_seconds,
        "address_space_bytes" => limits.address_space_bytes, "input_bytes" => limits.input_bytes,
        "output_bytes" => limits.output_bytes, "source_bytes" => limits.source_bytes,
        "max_tests" => limits.max_tests)
end

function compute_limits_from_dict(value::AbstractDict)
    allowed = Set(string.(fieldnames(ComputeLimits)))
    all(key -> key in allowed, keys(value)) || throw(ShenScopeError(:arguments, "Unknown compute limit"))
    ComputeLimits(; (Symbol(key) => item for (key, item) in value)...)
end

struct LinuxResourceLimit
    soft::UInt64
    hard::UInt64
end

function compute_set_resource_limit(resource::Cint, value::UInt64)
    limit = Ref(LinuxResourceLimit(value, value))
    ccall(:setrlimit, Cint, (Cint, Ref{LinuxResourceLimit}), resource, limit) == 0 ||
        throw(ShenScopeError(:sandbox, "Unable to apply compute resource limit"))
end

function compute_apply_resource_limits(limits::ComputeLimits)
    Sys.islinux() && Sys.WORD_SIZE == 64 ||
        throw(ShenScopeError(:sandbox, "Compute resource limits require verified 64-bit Linux"))
    # Hard limits cannot be raised after installation. RLIMIT_AS bounds virtual
    # address space, not resident memory. CPU time includes trusted bootstrap.
    compute_set_resource_limit(Cint(0), UInt64(limits.cpu_seconds))
    # LLVM's JIT uses an anonymous memfd. This cap also bounds that RAM object;
    # host files are independently excluded by descriptor audit and seccomp.
    compute_set_resource_limit(Cint(1), UInt64(128 * 1024^2))
    compute_set_resource_limit(Cint(4), UInt64(0))
    compute_set_resource_limit(Cint(9), limits.address_space_bytes)
    nothing
end
