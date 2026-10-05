function compiler_profile_measure(fixture::CompilerProfileFixture,limits::CompilerProfileLimits)
    warmup_started=time_ns()
    warm=compiler_profile_workload(fixture,limits.iterations)
    warmup_seconds=(time_ns()-warmup_started)/1e9
    expected=compiler_profile_output(warm)
    rows=Dict{String,Any}[]
    for batch in 1:limits.repetitions
        result=@timed compiler_profile_workload(fixture,limits.iterations)
        output=compiler_profile_output(result.value)
        output==expected || throw(ShenScopeError(:diagnostics,"Fixed profiling workload output changed between passes"))
        push!(rows,merge(Dict("batch"=>batch,"seconds"=>result.time,"gc_seconds"=>result.gctime,
            "allocated_bytes"=>result.bytes,"compile_seconds"=>result.compile_time,
            "recompile_seconds"=>result.recompile_time),output))
    end
    (rows=rows,warmup_seconds=warmup_seconds,expected=expected)
end

function compiler_profile_sample(fixture::CompilerProfileFixture,limits::CompilerProfileLimits,snapshot)
    Profile.Allocs.clear()
    try
        Profile.Allocs.start(;sample_rate=limits.sample_rate)
        value=try
            compiler_profile_workload(fixture,limits.iterations)
        finally
            Profile.Allocs.stop()
        end
        allocations=Profile.Allocs.fetch().allocs
        rows=compiler_profile_allocation_samples(allocations,snapshot,limits)
        (rows=rows,observed=length(allocations),output=compiler_profile_output(value))
    finally
        Profile.Allocs.clear()
    end
end
