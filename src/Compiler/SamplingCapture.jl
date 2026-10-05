@noinline function compiler_sampling_loop(fixture::CompilerProfileFixture,iterations::Int,seconds::Float64)
    started=time_ns();batches=0;checksum=0;value=nothing
    while batches<COMPILER_SAMPLING_MAX_BATCHES && (time_ns()-started)/1e9<seconds
        value=compiler_profile_workload(fixture,iterations)
        checksum=xor(checksum,value.checksum);batches+=1
    end
    value!==nothing || throw(ShenScopeError(:diagnostics,"Sampling workload completed no fixture batch"))
    (batches=batches,elapsed_seconds=(time_ns()-started)/1e9,checksum=checksum,
        batch_limit_reached=batches==COMPILER_SAMPLING_MAX_BATCHES,output=compiler_profile_output(value))
end

function compiler_sampling_capture(fixture::CompilerProfileFixture,limits::CompilerSamplingLimits,snapshot)
    warm_started=time_ns()
    warm=compiler_sampling_loop(fixture,limits.iterations,0.01)
    warm_seconds=(time_ns()-warm_started)/1e9
    Profile.init(;n=limits.buffer_words,delay=limits.delay_seconds,limitwarn=false)
    Profile.clear()
    try
        captured_started=time_ns()
        value=Profile.@profile compiler_sampling_loop(fixture,limits.iterations,limits.duration_seconds)
        instrumented_seconds=(time_ns()-captured_started)/1e9
        full=Profile.is_buffer_full()
        data=Profile.fetch(;include_meta=false,limitwarn=false)
        prefix=compiler_sampling_raw_prefix(data,limits;threads=Threads.nthreads())
        selected=UInt[]
        for stack in prefix.stacks;append!(selected,stack);push!(selected,zero(UInt));end
        lookup=Profile.getdict(selected)
        rows=compiler_sampling_decode(prefix,lookup,snapshot,limits)
        warm.output==value.output || throw(ShenScopeError(:diagnostics,"Sampling fixture output differs from warmup"))
        (warm=Dict("minimum_loop_seconds"=>0.01,"elapsed_seconds"=>warm_seconds,"batches"=>warm.batches,
            "output"=>warm.output,"included_in_sampling"=>false),
            run=Dict("requested_loop_seconds"=>limits.duration_seconds,"loop_elapsed_seconds"=>value.elapsed_seconds,
                "instrumented_elapsed_seconds"=>instrumented_seconds,"batches"=>value.batches,
                "iterations_per_batch"=>limits.iterations,"batch_limit_reached"=>value.batch_limit_reached,
                "consumption_checksum"=>value.checksum,"output"=>value.output),
            rows=rows,buffer=Dict("configured_words_per_thread"=>limits.buffer_words,"captured_instruction_words"=>prefix.words,
                "full"=>full,"metadata_exported"=>false),observed=prefix.observed)
    finally
        Profile.stop_timer();Profile.clear()
    end
end
