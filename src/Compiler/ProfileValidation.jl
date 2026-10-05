function compiler_profile_validate_frame(value,snapshot)
    compiler_ir_fields(value,["file","line","function","source_sha256","inlined","role"],"allocation frame")
    file=compiler_ir_text(value["file"],"allocation source file",512)
    startswith(file,"src/") || throw(ShenScopeError(:diagnostics,"Allocation frame is outside authored Core"))
    index=findfirst(row->row.path==file,snapshot.files)
    index!==nothing && value["source_sha256"]==snapshot.files[index].sha256 ||
        throw(ShenScopeError(:conflict,"Allocation source frame is absent or has a different source hash"))
    compiler_ir_integer(value["line"],"allocation source line",1,10_000_000)
    compiler_ir_text(value["function"],"allocation function",256)
    driver=startswith(file,"src/Compiler/Profile") || file=="src/Extensions/CompilerDiagnostics.jl"
    value["role"]==(driver ? "driver" : "core") && value["inlined"] isa Bool ||
        throw(ShenScopeError(:diagnostics,"Allocation frame role or inline flag changed"))
    nothing
end

function compiler_profile_validate_identity(identity,target,snapshot)
    expected=compiler_ir_method_identity(which(target.callable,target.arguments),snapshot)
    compiler_ir_fields(identity,collect(keys(expected)),"profiling method identity")
    for key in ("module","signature","file","line","source_sha256","argument_slots")
        identity[key]==expected[key] || throw(ShenScopeError(:diagnostics,"Profile method differs from the fixed trusted target"))
    end
    for key in ("method_world_start","method_world_end")
        text=compiler_ir_text(identity[key],"profile method world",32)
        tryparse(UInt64,text)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid profile method world counter"))
    end
    nothing
end

function compiler_profile_validate_timings(rows,limits)
    rows isa AbstractVector && length(rows)==limits.repetitions ||
        throw(ShenScopeError(:diagnostics,"Profile measurement batches are incomplete"))
    output=nothing
    for (batch,row) in enumerate(rows)
        compiler_ir_fields(row,["batch","seconds","gc_seconds","allocated_bytes","compile_seconds",
            "recompile_seconds","output_sha256","output_bytes","checksum"],"profile timing batch")
        compiler_ir_integer(row["batch"],"timing batch",batch,batch)
        for key in ("seconds","gc_seconds","compile_seconds","recompile_seconds")
            compiler_profile_seconds(row[key],key)
        end
        compiler_ir_integer(row["allocated_bytes"],"measured allocation bytes",0,2^40)
        compiler_ir_integer(row["output_bytes"],"fixture output bytes",0,16*1024)
        compiler_ir_integer(row["checksum"],"fixture loop checksum",0,16*1024)
        compiler_archive_hash(row["output_sha256"],"profile output hash")
        current=Dict(key=>row[key] for key in ("output_sha256","output_bytes","checksum"))
        if output===nothing
            output=current
        else
            current==output || throw(ShenScopeError(:diagnostics,"Profile output differs between timing passes"))
        end
        expected_checksum=isodd(limits.iterations) ? row["output_bytes"] : 0
        row["checksum"]==expected_checksum || throw(ShenScopeError(:diagnostics,"Profile workload consumption checksum disagrees"))
    end
    nothing
end

function compiler_profile_validate_samples(rows,summary,snapshot,limits)
    summary isa AbstractDict || throw(ShenScopeError(:diagnostics,"Invalid allocation summary"))
    observed=compiler_ir_integer(get(summary,"observed_samples",nothing),"observed allocation samples",0,COMPILER_PROFILE_MAX_OBSERVED)
    rows isa AbstractVector && length(rows)==min(observed,limits.max_samples) ||
        throw(ShenScopeError(:diagnostics,"Allocation retained prefix is incomplete"))
    for (id,row) in enumerate(rows)
        compiler_ir_fields(row,["id","type","bytes","core_frames","core_frames_truncated","stack_scan_truncated"],"allocation sample")
        compiler_ir_integer(row["id"],"allocation sample id",id,id)
        compiler_ir_text(row["type"],"allocation type",256)
        compiler_ir_integer(row["bytes"],"sampled allocation bytes",0,2^40)
        row["core_frames_truncated"] isa Bool && row["stack_scan_truncated"] isa Bool ||
            throw(ShenScopeError(:diagnostics,"Invalid allocation coverage flags"))
        frames=row["core_frames"]
        frames isa AbstractVector && length(frames)<=limits.max_frames ||
            throw(ShenScopeError(:diagnostics,"Allocation frame retention exceeds capacity"))
        for frame in frames;compiler_profile_validate_frame(frame,snapshot);end
        length(unique(canonical.(frames)))==length(frames) ||
            throw(ShenScopeError(:diagnostics,"Allocation source frames must be unique"))
        row["core_frames_truncated"] && length(frames)!=limits.max_frames &&
            throw(ShenScopeError(:diagnostics,"Truncated allocation frame prefix is incomplete"))
    end
    expected=compiler_profile_allocation_summary(rows,observed,limits)
    canonical(expected)==canonical(summary) || throw(ShenScopeError(:diagnostics,"Allocation aggregate projection disagrees"))
    nothing
end

function compiler_profile_validate_report(value,target::CompilerTarget,snapshot::RuntimeSourceSnapshot;
        limits=CompilerProfileLimits(),fixture="default",expected_threads=1)
    bounded_canonical_json(value;maximum=COMPILER_PROFILE_MAX_BYTES)
    fields=["schema","target","arguments","runtime","source","identity","fixture","limits","warmup","timings",
        "timing_summary","samples","allocation_summary","sample_output","elapsed_seconds","runtime_execution_observed",
        "output_consistent_across_passes","scope","measurement_notes","report_sha256"]
    compiler_ir_fields(value,fields,"profiling report")
    value["schema"]==COMPILER_PROFILE_SCHEMA && value["target"]==target.name &&
        value["arguments"]==string(target.arguments) && target.name in COMPILER_PROFILE_TARGETS ||
        throw(ShenScopeError(:diagnostics,"Profiling target, schema or signature changed"))
    value["source"]==Dict("fingerprint"=>snapshot.fingerprint,"uuid"=>string(snapshot.uuid),"version"=>string(snapshot.version)) ||
        throw(ShenScopeError(:conflict,"Profiling source inventory is stale"))
    runtime=value["runtime"]
    compiler_ir_fields(runtime,["julia_version","machine","observed_world","threads","profiler"],"profiling runtime")
    runtime["julia_version"]==string(Base.VERSION) && runtime["machine"]==string(Sys.MACHINE) && runtime["profiler"]=="Profile.Allocs" ||
        throw(ShenScopeError(:diagnostics,"Profiling runtime differs from the current compiler platform"))
    compiler_ir_integer(runtime["threads"],"profile helper threads",expected_threads,expected_threads)
    world=compiler_ir_text(runtime["observed_world"],"profile observed world",32)
    tryparse(UInt64,world)!==nothing || throw(ShenScopeError(:diagnostics,"Invalid profiling world counter"))
    compiler_profile_validate_identity(value["identity"],target,snapshot)
    normalized_limits=compiler_profile_limits_from_view(value["limits"])
    compiler_profile_limits_view(normalized_limits)==compiler_profile_limits_view(limits) &&
        value["fixture"]==compiler_profile_fixture(target.name,fixture).metadata &&
        get(value["fixture"],"user_input_accepted",nothing)===false ||
        throw(ShenScopeError(:diagnostics,"Profiling limits or fixed fixture changed"))
    compiler_ir_fields(value["warmup"],["batches","iterations","seconds","included_in_timing","output"],"profile warmup")
    value["warmup"]["batches"]===1 && value["warmup"]["iterations"]==limits.iterations &&
        value["warmup"]["included_in_timing"]===false || throw(ShenScopeError(:diagnostics,"Profiling warmup scope changed"))
    compiler_ir_integer(value["warmup"]["iterations"],"warmup iterations",limits.iterations,limits.iterations)
    compiler_profile_seconds(value["warmup"]["seconds"],"warmup seconds")
    compiler_profile_validate_timings(value["timings"],limits)
    expected_output=Dict(key=>value["timings"][1][key] for key in ("output_sha256","output_bytes","checksum"))
    canonical(value["warmup"]["output"])==canonical(expected_output) &&
        canonical(value["sample_output"])==canonical(expected_output) ||
        throw(ShenScopeError(:diagnostics,"Profiling outputs do not agree across warmup, timing and sampling passes"))
    canonical(value["timing_summary"])==canonical(compiler_profile_timing_summary(value["timings"])) ||
        throw(ShenScopeError(:diagnostics,"Profiling timing aggregate projection disagrees"))
    compiler_profile_validate_samples(value["samples"],value["allocation_summary"],snapshot,limits)
    compiler_profile_seconds(value["elapsed_seconds"],"elapsed seconds")
    value["runtime_execution_observed"]===true && value["output_consistent_across_passes"]===true &&
        value["scope"]==COMPILER_PROFILE_SCOPE || throw(ShenScopeError(:diagnostics,"Profiling execution scope changed"))
    notes=value["measurement_notes"]
    notes==COMPILER_PROFILE_NOTES || throw(ShenScopeError(:diagnostics,"Profiling measurement qualifiers changed"))
    checksum=compiler_archive_hash(value["report_sha256"],"profiling report hash")
    digest(canonical(Dict(key=>item for (key,item) in value if key!="report_sha256")))==checksum ||
        throw(ShenScopeError(:conflict,"Profiling report digest changed"))
    value
end
