function compiler_profile_report(name::AbstractString;fixture="default",limits=CompilerProfileLimits(),
        expected_source_fingerprint=nothing)
    input=compiler_profile_fixture(name,fixture);root=runtime_core_root();started=time_ns()
    ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,
        :edit=>Deny,:process=>Deny,:network=>Deny,:persistence=>Deny,:dynamic=>Deny)))
    snapshot=runtime_source_snapshot(ctx;root)
    expected_source_fingerprint===nothing || expected_source_fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Profile caller source fingerprint is stale before workload execution"))
    identity=compiler_ir_method_identity(which(input.target.callable,input.target.arguments),snapshot)
    measured=compiler_profile_measure(input,limits)
    sampled=compiler_profile_sample(input,limits,snapshot)
    sampled.output==measured.expected || throw(ShenScopeError(:diagnostics,"Profiling changed the observed fixture output"))
    runtime_source_snapshot(ctx;root,authorized=true).fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Core source changed during runtime profiling"))
    report=Dict("schema"=>COMPILER_PROFILE_SCHEMA,"target"=>name,"arguments"=>string(input.target.arguments),
        "runtime"=>Dict("julia_version"=>string(Base.VERSION),"machine"=>string(Sys.MACHINE),
            "observed_world"=>string(Base.get_world_counter()),"threads"=>Threads.nthreads(),"profiler"=>"Profile.Allocs"),
        "source"=>Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)),
        "identity"=>identity,"fixture"=>input.metadata,"limits"=>compiler_profile_limits_view(limits),
        "warmup"=>Dict("batches"=>1,"iterations"=>limits.iterations,"seconds"=>measured.warmup_seconds,
            "included_in_timing"=>false,"output"=>measured.expected),"timings"=>measured.rows,
        "timing_summary"=>compiler_profile_timing_summary(measured.rows),"samples"=>sampled.rows,
        "allocation_summary"=>compiler_profile_allocation_summary(sampled.rows,sampled.observed,limits),
        "sample_output"=>sampled.output,
        "elapsed_seconds"=>(time_ns()-started)/1e9,"runtime_execution_observed"=>true,
        "output_consistent_across_passes"=>true,"scope"=>COMPILER_PROFILE_SCOPE,
        "measurement_notes"=>copy(COMPILER_PROFILE_NOTES))
    report["report_sha256"]=digest(canonical(report))
    bounded_canonical_json(report;maximum=COMPILER_PROFILE_MAX_BYTES)
    report
end
