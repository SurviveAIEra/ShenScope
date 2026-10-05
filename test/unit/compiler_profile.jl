profile_fixture_rehash!(value)=(value["report_sha256"]=digest(canonical(Dict(key=>item for (key,item) in value if key!="report_sha256")));value)

@testset "Runtime profile limits and fixture contracts refuse unbounded or irrelevant input" begin
    @test ShenScope.CompilerProfileLimits().sample_rate==1.0
    for args in ((;iterations=true),(;iterations=33),(;repetitions=0),(;repetitions=9),
            (;max_samples=257),(;max_frames=9),(;sample_rate=true),(;sample_rate=0),(;sample_rate=Inf),(;sample_rate=NaN))
        @test_throws ShenScopeError ShenScope.CompilerProfileLimits(;args...)
    end
    @test_throws ShenScopeError ShenScope.compiler_profile_fixture("remove_graph_edge")
    @test_throws ShenScopeError ShenScope.compiler_profile_fixture("digest_string","nested_dictionary")
    @test_throws ShenScopeError ShenScope.compiler_profile_fixture("canonical_dictionary","unicode")
    @test ShenScope.compiler_profile_fixture("cliptext_string").metadata["input_kind"]=="string"
    @test !ShenScope.compiler_profile_fixture("canonical_dictionary").metadata["user_input_accepted"]
    @test_throws ShenScopeError ShenScope.diagnostics_arguments(Dict("action"=>"profile","target"=>"digest_string","mode"=>"graph"))
end

@testset "Actual timed workloads and allocation samples have independently checked summaries" begin
    ctx=RuntimeContext(ShenScope.runtime_core_root();permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    limits=ShenScope.CompilerProfileLimits(;iterations=2,repetitions=2,max_samples=16,max_frames=2)
    snapshot=runtime_source_snapshot(ctx)
    reports=Dict{String,Any}[]
    for name in ShenScope.COMPILER_PROFILE_TARGETS
        report=ShenScope.compiler_profile_report(name;limits)
        push!(reports,report)
        validated=ShenScope.compiler_profile_validate_report(parsejson(canonical(report)),ShenScope.compiler_target(name),snapshot;
            limits,expected_threads=Threads.nthreads())
        @test validated["target"]==name && report["runtime_execution_observed"]
        @test length(report["timings"])==2 && !report["warmup"]["included_in_timing"]
        @test all(row->row["seconds"]>=0 && row["allocated_bytes"]>0,report["timings"])
        @test report["allocation_summary"]["observed_samples"]>=length(report["samples"])>0
        @test report["allocation_summary"]["samples_with_core_frames"]>0
        @test all(row->length(row["core_frames"])<=2,report["samples"])
        @test !occursin(snapshot.root,canonical(report))
        @test sum(row["sampled_bytes"] for row in report["allocation_summary"]["types"])==
            sum(row["bytes"] for row in report["samples"])
    end
    report=first(reports)
    validate=value->ShenScope.compiler_profile_validate_report(value,ShenScope.compiler_target("digest_string"),snapshot;
        limits,expected_threads=Threads.nthreads())
    frame_index=findfirst(row->!isempty(row["core_frames"]),report["samples"])
    corruptions=[
        value->(value["source"]["fingerprint"]=repeat("0",64)),
        value->(value["limits"]["iterations"]=true),
        value->(value["runtime"]["threads"]=0),
        value->(value["samples"][1]["bytes"]=true),
        value->(value["samples"][frame_index]["core_frames"][1]["file"]="../outside.jl"),
        value->(value["samples"][frame_index]["core_frames"][1]["source_sha256"]=repeat("0",64)),
        value->(value["allocation_summary"]["types"][1]["samples"]+=1),
        value->(value["timing_summary"]["median_seconds"]+=1),
        value->(value["timings"][1]["output_sha256"]=repeat("0",64)),
        value->(value["warmup"]["output"]["output_sha256"]=repeat("0",64)),
        value->(value["sample_output"]["output_bytes"]+=1),
        value->(value["runtime_execution_observed"]=false),
        value->(value["fixture"]["user_input_accepted"]=0),
        value->(value["measurement_notes"][1]="Guaranteed faster and allocation free"),
        value->(value["warmup"]["iterations"]=true),
        value->push!(value["samples"][1]["core_frames"],Dict("pointer"=>"forbidden"))]
    for corrupt in corruptions
        value=deepcopy(report);corrupt(value);profile_fixture_rehash!(value)
        @test_throws ShenScopeError validate(value)
    end
    altered=deepcopy(report);altered["elapsed_seconds"]+=1
    @test_throws ShenScopeError validate(altered)
    @test_throws ShenScopeError ShenScope.compiler_profile_report("digest_string";limits,expected_source_fingerprint=repeat("0",64))
    # Synthetic absence of retained allocations must remain distinguishable
    # from the nonzero measured bytes in the actual timing passes.
    empty_limits=ShenScope.CompilerProfileLimits(;iterations=2,repetitions=2,max_samples=16,max_frames=2,sample_rate=0.001)
    absent=deepcopy(report);absent["limits"]=ShenScope.compiler_profile_limits_view(empty_limits)
    absent["samples"]=Any[];absent["allocation_summary"]=ShenScope.compiler_profile_allocation_summary(Any[],0,empty_limits)
    profile_fixture_rehash!(absent)
    @test ShenScope.compiler_profile_validate_report(absent,ShenScope.compiler_target("digest_string"),snapshot;
        limits=empty_limits,expected_threads=Threads.nthreads())["allocation_summary"]["retained_samples"]==0
    @test absent["timing_summary"]["median_allocated_bytes"]>0
end
