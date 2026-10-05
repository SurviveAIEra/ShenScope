@testset "Periodic sampling rejects unbounded inputs and decodes a bounded address-free prefix" begin
    limits=ShenScope.CompilerSamplingLimits(;max_samples=2,max_frames=2,buffer_words=4096)
    @test ShenScope.compiler_sampling_limits_from_view(ShenScope.compiler_sampling_limits_view(limits))==limits
    for options in ((;iterations=true),(;iterations=33),(;duration_seconds=0),(;duration_seconds=Inf),
            (;duration_seconds=NaN),(;delay_seconds=true),(;delay_seconds=0),(;delay_seconds=0.02),
            (;duration_seconds=0.01,delay_seconds=0.01),(;max_samples=257),(;max_frames=0),(;buffer_words=4095),(;buffer_words=200_001))
        @test_throws ShenScopeError ShenScope.CompilerSamplingLimits(;options...)
    end
    for args in (Dict("action"=>"sample","target"=>"digest_string","mode"=>"graph"),
            Dict("action"=>"sample","target"=>"digest_string","sample_rate"=>1),Dict("action"=>"sample"))
        @test_throws ShenScopeError ShenScope.diagnostics_arguments(args)
    end
    @test_throws ShenScopeError ShenScope.compiler_sampling_raw_prefix(UInt[1],limits)
    @test_throws ShenScopeError ShenScope.compiler_sampling_raw_prefix(zeros(UInt,4097),limits)
    @test_throws ShenScopeError ShenScope.compiler_sampling_raw_prefix(UInt[],limits;threads=true)
    @test ShenScope.compiler_sampling_raw_prefix(UInt[],limits).observed==0
    raw=UInt[1,1,2,3,4,0];append!(raw,fill(UInt(9),140));append!(raw,UInt[0,1,0])
    prefix=ShenScope.compiler_sampling_raw_prefix(raw,limits)
    @test prefix.observed==3 && prefix.sizes==[5,140] && length(prefix.stacks[2])==128
    ctx=RuntimeContext(ShenScope.runtime_core_root();permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    snapshot=runtime_source_snapshot(ctx)
    source=joinpath(snapshot.root,"src","Core","Types.jl")
    frame=line->(file=source,line=line,func=Symbol("frame$line"),inlined=false)
    external=(file="/outside/private-host-user/home/secret.jl",line=1,func=:outside,inlined=false)
    lookup=Dict(UInt(1)=>[frame(10)],UInt(2)=>[external],UInt(3)=>[frame(11)],UInt(4)=>[frame(12)],UInt(9)=>fill(frame(13),3))
    rows=ShenScope.compiler_sampling_decode(prefix,lookup,snapshot,limits)
    @test getindex.(rows[1]["core_frames"],"line")==[10,11]
    @test rows[1]["core_frames_truncated"] && !rows[1]["stack_scan_truncated"]
    @test rows[2]["stack_scan_truncated"] && rows[2]["lookup_scan_truncated"]
    @test length(rows[2]["core_frames"])==1 && !rows[2]["core_frames_truncated"]
    @test !occursin("private-host-user",canonical(rows)) && !occursin(snapshot.root,canonical(rows))
    @test_throws ShenScopeError ShenScope.compiler_sampling_decode(prefix,Dict{UInt,Any}(),snapshot,limits)
    summary=ShenScope.compiler_sampling_summary(rows,prefix.observed,limits)
    oracle=Dict{String,Int}()
    for row in rows,frame in row["core_frames"];key=canonical(frame);oracle[key]=get(oracle,key,0)+1;end
    @test sort(getindex.(summary["top_frames"],"retained_backtraces"))==sort(collect(values(oracle)))
    @test all(frame->frame["fraction_of_retained_backtraces"]==frame["retained_backtraces"]/length(rows),summary["top_frames"])
    @test summary["samples_truncated"] && !summary["cpu_utilization_measured"] && !summary["frame_counts_are_additive"]
    @test ShenScope.compiler_sampling_validate_samples(rows,summary,snapshot,limits)==3
end

@testset "Real periodic backtraces retain checked source frames and explicit measurement limits" begin
    ctx=RuntimeContext(ShenScope.runtime_core_root();permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    limits=ShenScope.CompilerSamplingLimits(;iterations=2,duration_seconds=0.03,max_samples=12,max_frames=2,buffer_words=4096)
    snapshot=runtime_source_snapshot(ctx);reports=Dict{String,Any}[]
    for name in ShenScope.COMPILER_PROFILE_TARGETS
        report=ShenScope.compiler_sampling_report(name;limits);push!(reports,report)
        validated=ShenScope.compiler_sampling_validate_report(parsejson(canonical(report)),ShenScope.compiler_target(name),snapshot;
            limits,expected_threads=Threads.nthreads())
        @test validated["runtime_execution_observed"] && report["target"]==name
        @test report["run"]["loop_elapsed_seconds"]>=limits.duration_seconds || report["run"]["batch_limit_reached"]
        @test report["warmup"]["output"]==report["run"]["output"] && !report["warmup"]["included_in_sampling"]
        @test report["sampling_summary"]["retained_backtraces"]<=12
        @test !report["buffer"]["metadata_exported"] && !report["sampling_summary"]["cpu_utilization_measured"]
        @test !ShenScope.Profile.is_running() && isempty(ShenScope.Profile.fetch(;include_meta=false,limitwarn=false))
        @test !occursin(snapshot.root,canonical(report))
    end
    report=first(reports)
    validate=value->ShenScope.compiler_sampling_validate_report(value,ShenScope.compiler_target(report["target"]),snapshot;
        limits,expected_threads=Threads.nthreads())
    for corrupt in (value->(value["source"]["fingerprint"]=repeat("0",64)),value->(value["runtime"]["threads"]=0),
            value->(value["limits"]["iterations"]=true),value->(value["run"]["batches"]=true),
            value->(value["run"]["output"]["checksum"]+=1),value->(value["warmup"]["included_in_sampling"]=true),
            value->(value["run"]["consumption_checksum"]+=1),value->(value["sampling_summary"]["cpu_utilization_measured"]=true),
            value->(value["sampling_summary"]["observed_backtraces"]=0),value->(value["buffer"]["captured_instruction_words"]=limits.buffer_words*Threads.nthreads()+1),
            value->(value["buffer"]["metadata_exported"]=true),value->(value["buffer"]["full"]=0),
            value->(value["fixture"]["user_input_accepted"]=true),value->(value["runtime"]["observed_world"]="invalid"),
            value->(value["scope"]="exclusive CPU utilization"),value->(value["measurement_notes"][1]="Guaranteed faster"))
        changed=deepcopy(report);corrupt(changed);compiler_fixture_rehash!(changed)
        @test_throws ShenScopeError validate(changed)
    end
    positioned=first(row for value in reports for row in value["samples"] if !isempty(row["core_frames"]))
    @test positioned["core_frames"][1]["role"] in ("driver","core")
    for field in ("file","source_sha256","role")
        rows=deepcopy([positioned]);rows[1]["id"]=1
        rows[1]["core_frames"][1][field]=field=="source_sha256" ? repeat("0",64) : field=="role" ? "cpu" : "../private.jl"
        summary=ShenScope.compiler_sampling_summary(rows,1,limits)
        @test_throws ShenScopeError ShenScope.compiler_sampling_validate_samples(rows,summary,snapshot,limits;expected_threads=Threads.nthreads())
    end
    changed=deepcopy(report);changed["elapsed_seconds"]+=1
    @test_throws ShenScopeError validate(changed)
    @test_throws ShenScopeError ShenScope.compiler_sampling_report(report["target"];limits,expected_source_fingerprint=repeat("0",64))
    empty=deepcopy(report);empty["samples"]=Any[];empty["sampling_summary"]=ShenScope.compiler_sampling_summary(Any[],0,limits)
    empty["buffer"]["captured_instruction_words"]=0;empty["buffer"]["full"]=false;compiler_fixture_rehash!(empty)
    @test validate(empty)["sampling_summary"]["retained_backtraces"]==0
    @test empty["runtime_execution_observed"] && !empty["sampling_summary"]["cpu_utilization_measured"]
    @test !ShenScope.Profile.is_running()
end
