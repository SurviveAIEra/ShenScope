const COMPILER_PROFILE_SCHEMA="shenscope.compiler-profile/1"
const COMPILER_PROFILE_MAX_BYTES=2*1024^2
const COMPILER_PROFILE_TARGETS=("digest_string","cliptext_string","canonical_dictionary")
const COMPILER_PROFILE_MAX_STACK_SCAN=128
const COMPILER_PROFILE_MAX_OBSERVED=250_000
const COMPILER_PROFILE_SCOPE="fixed trusted Core function and typed workload driver; no project loading"
const COMPILER_PROFILE_NOTES=["Timing and allocation sampling run in separate passes after one warmup batch.",
    "Workload driver, returned tuple, scheduler noise and remaining compilation can affect measurements.",
    "Sampled allocation bytes need not equal timing-pass allocation bytes, even at sample rate one.",
    "Sampling can include helper background activity; no CPU, RSS, retained-heap or performance improvement is established."]

struct CompilerProfileLimits
    iterations::Int
    repetitions::Int
    max_samples::Int
    max_frames::Int
    sample_rate::Float64
    function CompilerProfileLimits(;iterations=8,repetitions=3,max_samples=128,max_frames=4,sample_rate=1.0)
        values=(iterations,repetitions,max_samples,max_frames)
        all(value->value isa Integer && !(value isa Bool),values) &&
            1<=iterations<=32 && 1<=repetitions<=8 && 1<=max_samples<=256 && 1<=max_frames<=8 ||
            throw(ShenScopeError(:diagnostics,"Profiling iteration, repetition or retention limits are invalid"))
        sample_rate isa Real && !(sample_rate isa Bool) && isfinite(sample_rate) && 0.001<=sample_rate<=1 ||
            throw(ShenScopeError(:diagnostics,"Profiling sample rate must be finite and between 0.001 and one"))
        new(Int.(values)...,Float64(sample_rate))
    end
end

compiler_profile_limits_view(limits::CompilerProfileLimits)=
    Dict(string(field)=>getfield(limits,field) for field in fieldnames(CompilerProfileLimits))

function compiler_profile_limits_from_view(value)
    compiler_ir_fields(value,string.(fieldnames(CompilerProfileLimits)),"profile limits")
    CompilerProfileLimits(;[Symbol(key)=>item for (key,item) in value]...)
end

function compiler_profile_target(name::AbstractString)
    name in COMPILER_PROFILE_TARGETS ||
        throw(ShenScopeError(:diagnostics,"Runtime measurement supports only the fixed nonmutating fixture target table"))
    compiler_target(name)
end

function compiler_profile_seconds(value,label)
    value isa Real && !(value isa Bool) && isfinite(value) && 0<=value<=3600 ||
        throw(ShenScopeError(:diagnostics,"Invalid profiling "*label))
    Float64(value)
end

function compiler_profile_median(values)
    ordered=sort!(collect(values));count=length(ordered)
    count>0 || throw(ShenScopeError(:diagnostics,"A profile measurement collection is empty"))
    middle=(count+1)÷2
    isodd(count) ? Float64(ordered[middle]) : Float64(ordered[middle]+ordered[middle+1])/2
end

function compiler_profile_timing_summary(rows)
    seconds=getindex.(rows,"seconds");bytes=getindex.(rows,"allocated_bytes")
    Dict("batches"=>length(rows),"minimum_seconds"=>minimum(seconds),"median_seconds"=>compiler_profile_median(seconds),
        "maximum_seconds"=>maximum(seconds),"minimum_allocated_bytes"=>minimum(bytes),
        "median_allocated_bytes"=>compiler_profile_median(bytes),"maximum_allocated_bytes"=>maximum(bytes),
        "gc_seconds"=>sum(row["gc_seconds"] for row in rows),
        "compile_seconds"=>sum(row["compile_seconds"] for row in rows),
        "recompile_seconds"=>sum(row["recompile_seconds"] for row in rows),
        "scope"=>"one workload batch; includes the fixture call, loop and returned batch tuple",
        "sampling_instrumentation_included"=>false)
end
