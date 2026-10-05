function compiler_sampling_validate_output(value,iterations)
    compiler_ir_fields(value,["output_sha256","output_bytes","checksum"],"sampling output")
    compiler_archive_hash(value["output_sha256"],"sampled output hash")
    bytes=compiler_ir_integer(value["output_bytes"],"sampled output bytes",0,16*1024)
    checksum=compiler_ir_integer(value["checksum"],"sampled output checksum",0,16*1024)
    checksum==(isodd(iterations) ? bytes : 0) || throw(ShenScopeError(:diagnostics,"Sampling batch output consumption disagrees"))
end

function compiler_sampling_validate_samples(rows,summary,snapshot,limits;expected_threads=1)
    summary isa AbstractDict || throw(ShenScopeError(:diagnostics,"Invalid periodic sampling summary"))
    observed=compiler_ir_integer(get(summary,"observed_backtraces",nothing),"observed backtraces",0,limits.buffer_words*expected_threads)
    rows isa AbstractVector && length(rows)==min(observed,limits.max_samples) ||
        throw(ShenScopeError(:diagnostics,"Periodic sampling retained prefix is incomplete"))
    for (id,row) in enumerate(rows)
        compiler_ir_fields(row,["id","core_frames","core_frames_truncated","stack_scan_truncated","lookup_scan_truncated"],"periodic backtrace")
        compiler_ir_integer(row["id"],"backtrace id",id,id)
        all(key->row[key] isa Bool,("core_frames_truncated","stack_scan_truncated","lookup_scan_truncated")) ||
            throw(ShenScopeError(:diagnostics,"Sampling coverage flags must be boolean"))
        frames=row["core_frames"]
        frames isa AbstractVector && length(frames)<=limits.max_frames || throw(ShenScopeError(:diagnostics,"Sampling frame retention exceeds capacity"))
        for frame in frames;compiler_profile_validate_frame(frame,snapshot);end
        length(unique(canonical.(frames)))==length(frames) || throw(ShenScopeError(:diagnostics,"Sampling frames must be unique"))
        row["core_frames_truncated"] && length(frames)!=limits.max_frames &&
            throw(ShenScopeError(:diagnostics,"Truncated sampling frame prefix is incomplete"))
    end
    canonical(summary)==canonical(compiler_sampling_summary(rows,observed,limits)) ||
        throw(ShenScopeError(:diagnostics,"Periodic sampling aggregate projection disagrees"))
    observed
end

function compiler_sampling_validate_report(value,target::CompilerTarget,snapshot::RuntimeSourceSnapshot;
        limits=CompilerSamplingLimits(),fixture="default",expected_threads=1)
    bounded_canonical_json(value;maximum=COMPILER_SAMPLING_MAX_BYTES)
    compiler_ir_fields(value,["schema","target","arguments","runtime","source","identity","fixture","limits",
        "warmup","run","buffer","samples","sampling_summary","elapsed_seconds","runtime_execution_observed",
        "output_consistent_across_passes","scope","measurement_notes","report_sha256"],"periodic sampling report")
    value["schema"]==COMPILER_SAMPLING_SCHEMA && value["target"]==target.name && target.name in COMPILER_PROFILE_TARGETS &&
        value["arguments"]==string(target.arguments) || throw(ShenScopeError(:diagnostics,"Sampling target or schema changed"))
    value["source"]==Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)) ||
        throw(ShenScopeError(:conflict,"Sampling source inventory is stale"))
    runtime=value["runtime"]
    compiler_ir_fields(runtime,["julia_version","machine","observed_world","threads","profiler"],"sampling runtime")
    runtime["julia_version"]==string(Base.VERSION) && runtime["machine"]==string(Sys.MACHINE) && runtime["profiler"]=="Profile.periodic_backtraces" ||
        throw(ShenScopeError(:diagnostics,"Sampling runtime changed"))
    compiler_ir_integer(runtime["threads"],"sampling helper threads",expected_threads,expected_threads)
    world=compiler_ir_text(runtime["observed_world"],"sampling observed world",32)
    tryparse(UInt64,world)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid sampling world counter"))
    compiler_profile_validate_identity(value["identity"],target,snapshot)
    normalized=compiler_sampling_limits_from_view(value["limits"])
    compiler_sampling_limits_view(normalized)==compiler_sampling_limits_view(limits) &&
        value["fixture"]==compiler_profile_fixture(target.name,fixture).metadata && get(value["fixture"],"user_input_accepted",nothing)===false ||
        throw(ShenScopeError(:diagnostics,"Sampling limits or fixed fixture changed"))
    warm=value["warmup"];run=value["run"]
    compiler_ir_fields(warm,["minimum_loop_seconds","elapsed_seconds","batches","output","included_in_sampling"],"sampling warmup")
    warm["minimum_loop_seconds"]===0.01 && warm["included_in_sampling"]===false || throw(ShenScopeError(:diagnostics,"Sampling warmup scope changed"))
    compiler_ir_integer(warm["batches"],"sampling warmup batches",1,COMPILER_SAMPLING_MAX_BATCHES)
    compiler_profile_seconds(warm["elapsed_seconds"],"sampling warmup elapsed")
    compiler_ir_fields(run,["requested_loop_seconds","loop_elapsed_seconds","instrumented_elapsed_seconds","batches",
        "iterations_per_batch","batch_limit_reached","consumption_checksum","output"],"sampling run")
    run["requested_loop_seconds"]==limits.duration_seconds || throw(ShenScopeError(:diagnostics,"Sampling duration changed"))
    compiler_profile_seconds(run["requested_loop_seconds"],"sampling requested duration")
    loop=compiler_profile_seconds(run["loop_elapsed_seconds"],"sampling loop elapsed")
    instrumented=compiler_profile_seconds(run["instrumented_elapsed_seconds"],"sampling instrumented elapsed")
    instrumented>=loop || throw(ShenScopeError(:diagnostics,"Sampling instrumented elapsed is below loop elapsed"))
    batches=compiler_ir_integer(run["batches"],"sampling workload batches",1,COMPILER_SAMPLING_MAX_BATCHES)
    compiler_ir_integer(run["iterations_per_batch"],"sampling iterations",limits.iterations,limits.iterations)
    run["batch_limit_reached"]===(batches==COMPILER_SAMPLING_MAX_BATCHES) && (run["batch_limit_reached"] || loop>=limits.duration_seconds) ||
        throw(ShenScopeError(:diagnostics,"Sampling workload stopped before its duration or batch bound"))
    compiler_sampling_validate_output(warm["output"],limits.iterations);compiler_sampling_validate_output(run["output"],limits.iterations)
    warm["output"]==run["output"] || throw(ShenScopeError(:diagnostics,"Sampling output differs across passes"))
    checksum=compiler_ir_integer(run["consumption_checksum"],"sampling loop consumption",0,16*1024)
    checksum==(isodd(batches) ? run["output"]["checksum"] : 0) || throw(ShenScopeError(:diagnostics,"Sampling loop output consumption disagrees"))
    buffer=value["buffer"];compiler_ir_fields(buffer,["configured_words_per_thread","captured_instruction_words","full","metadata_exported"],"sampling buffer")
    compiler_ir_integer(buffer["configured_words_per_thread"],"sampling buffer configuration",limits.buffer_words,limits.buffer_words)
    words=compiler_ir_integer(buffer["captured_instruction_words"],"captured sampling words",0,limits.buffer_words*expected_threads)
    buffer["full"] isa Bool && buffer["metadata_exported"]===false || throw(ShenScopeError(:diagnostics,"Sampling buffer coverage or privacy flags changed"))
    observed=compiler_sampling_validate_samples(value["samples"],value["sampling_summary"],snapshot,limits;expected_threads)
    observed<=words || throw(ShenScopeError(:diagnostics,"Sampling record count exceeds its captured word count"))
    value["runtime_execution_observed"]===true && value["output_consistent_across_passes"]===true &&
        value["scope"]==COMPILER_SAMPLING_SCOPE && value["measurement_notes"]==COMPILER_SAMPLING_NOTES ||
        throw(ShenScopeError(:diagnostics,"Sampling execution scope or qualifiers changed"))
    compiler_profile_seconds(value["elapsed_seconds"],"sampling report elapsed")
    checksum=compiler_archive_hash(value["report_sha256"],"sampling report hash")
    digest(canonical(Dict(key=>item for (key,item) in value if key!="report_sha256")))==checksum ||
        throw(ShenScopeError(:conflict,"Sampling report digest changed"))
    value
end
