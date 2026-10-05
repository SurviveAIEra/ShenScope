const COMPILER_SAMPLING_SCHEMA="shenscope.compiler-sampling/1"
const COMPILER_SAMPLING_MAX_BYTES=2*1024^2
const COMPILER_SAMPLING_MAX_BATCHES=100_000
const COMPILER_SAMPLING_MAX_LOOKUP_FRAMES=256
const COMPILER_SAMPLING_SCOPE="periodic helper backtraces during a fixed Core fixture; all helper tasks, not exclusive CPU utilization"
const COMPILER_SAMPLING_NOTES=["Warmup precedes a separate periodic backtrace collection pass.",
    "Requested duration is a minimum loop window; driver, remaining compilation, GC and scheduling can extend elapsed time.",
    "Samples can include helper background activity; task and instruction-pointer identities are not exported.",
    "Frame fractions count retained backtraces, not CPU utilization, exclusive function time or a performance improvement.",
    "Empty or truncated samples cannot establish absence of CPU work."]

struct CompilerSamplingLimits
    iterations::Int
    duration_seconds::Float64
    delay_seconds::Float64
    max_samples::Int
    max_frames::Int
    buffer_words::Int
    function CompilerSamplingLimits(;iterations=8,duration_seconds=0.1,delay_seconds=0.001,
            max_samples=128,max_frames=4,buffer_words=20_000)
        integers=(iterations,max_samples,max_frames,buffer_words)
        all(value->value isa Integer && !(value isa Bool),integers) && 1<=iterations<=32 &&
            1<=max_samples<=256 && 1<=max_frames<=8 && 4096<=buffer_words<=200_000 ||
            throw(ShenScopeError(:diagnostics,"Sampling iteration, retention or buffer limits exceed bounds"))
        all(value->value isa Real && !(value isa Bool) && isfinite(value),(duration_seconds,delay_seconds)) &&
            0.01<=duration_seconds<=1 && 0.0001<=delay_seconds<=0.01 && delay_seconds*2<=duration_seconds ||
            throw(ShenScopeError(:diagnostics,"Sampling duration and delay must be finite within supported bounds"))
        new(Int(iterations),Float64(duration_seconds),Float64(delay_seconds),Int(max_samples),Int(max_frames),Int(buffer_words))
    end
end

compiler_sampling_limits_view(limits::CompilerSamplingLimits)=
    Dict(string(field)=>getfield(limits,field) for field in fieldnames(CompilerSamplingLimits))

function compiler_sampling_limits_from_view(value)
    compiler_ir_fields(value,string.(fieldnames(CompilerSamplingLimits)),"sampling limits")
    CompilerSamplingLimits(;[Symbol(key)=>item for (key,item) in value]...)
end

function compiler_sampling_summary(rows,observed,limits::CompilerSamplingLimits)
    locations=Dict{String,Tuple{Dict{String,Any},Int}}()
    for row in rows,frame in row["core_frames"]
        key=canonical(frame);previous,amount=get(locations,key,(frame,0))
        locations[key]=(previous,amount+1)
    end
    frames=[merge(frame,Dict("retained_backtraces"=>amount,
        "fraction_of_retained_backtraces"=>isempty(rows) ? 0.0 : amount/length(rows))) for (frame,amount) in values(locations)]
    sort!(frames;by=row->(-row["retained_backtraces"],row["file"],row["line"],row["function"],row["inlined"]))
    Dict("observed_backtraces"=>observed,"retained_backtraces"=>length(rows),"samples_truncated"=>observed>length(rows),
        "backtraces_with_core_frames"=>count(row->!isempty(row["core_frames"]),rows),
        "core_frame_lists_truncated"=>count(row->row["core_frames_truncated"],rows),
        "stack_scans_truncated"=>count(row->row["stack_scan_truncated"],rows),
        "lookup_scans_truncated"=>count(row->row["lookup_scan_truncated"],rows),"top_frames"=>frames,
        "attribution"=>"inclusive source-frame occurrences within the retained backtrace prefix",
        "sample_delay_seconds"=>limits.delay_seconds,"frame_counts_are_additive"=>false,
        "cpu_utilization_measured"=>false,"task_and_instruction_pointer_identities_exposed"=>false)
end
