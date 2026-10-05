function compiler_sampling_report(name::AbstractString;fixture="default",limits=CompilerSamplingLimits(),expected_source_fingerprint=nothing)
    input=compiler_profile_fixture(name,fixture);root=runtime_core_root();started=time_ns()
    ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,
        :edit=>Deny,:process=>Deny,:network=>Deny,:persistence=>Deny,:dynamic=>Deny)))
    snapshot=runtime_source_snapshot(ctx;root)
    expected_source_fingerprint===nothing || expected_source_fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Sampling caller source fingerprint is stale before workload execution"))
    identity=compiler_ir_method_identity(which(input.target.callable,input.target.arguments),snapshot)
    captured=compiler_sampling_capture(input,limits,snapshot)
    runtime_source_snapshot(ctx;root,authorized=true).fingerprint==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Core source changed during periodic sampling"))
    report=Dict("schema"=>COMPILER_SAMPLING_SCHEMA,"target"=>name,"arguments"=>string(input.target.arguments),
        "runtime"=>Dict("julia_version"=>string(Base.VERSION),"machine"=>string(Sys.MACHINE),
            "observed_world"=>string(Base.get_world_counter()),"threads"=>Threads.nthreads(),"profiler"=>"Profile.periodic_backtraces"),
        "source"=>Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)),
        "identity"=>identity,"fixture"=>input.metadata,"limits"=>compiler_sampling_limits_view(limits),
        "warmup"=>captured.warm,"run"=>captured.run,"buffer"=>captured.buffer,"samples"=>captured.rows,
        "sampling_summary"=>compiler_sampling_summary(captured.rows,captured.observed,limits),
        "elapsed_seconds"=>(time_ns()-started)/1e9,"runtime_execution_observed"=>true,
        "output_consistent_across_passes"=>true,"scope"=>COMPILER_SAMPLING_SCOPE,"measurement_notes"=>copy(COMPILER_SAMPLING_NOTES))
    report["report_sha256"]=digest(canonical(report))
    bounded_canonical_json(report;maximum=COMPILER_SAMPLING_MAX_BYTES)
    report
end
