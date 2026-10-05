@testset "Actual inferred IR preserves branch definitions, loop flow and compiler scope" begin
    branch=compiler_fixture_graph(CompilerIRFixtures.branch,Tuple{Bool})
    @test branch["return_type"]["classification"]=="small_concrete_union"
    reads=[row for row in branch["slot_flow"]["reads"] if length(row["possible_definitions"])==2]
    @test !isempty(reads)
    @test all(!row["possibly_uninitialized"] for row in reads)
    @test all(!row["runtime_value_observed"] for row in reads)
    loop=compiler_fixture_graph(CompilerIRFixtures.loop,Tuple{Int})
    @test length(loop["control_flow"]["loops"]["cycle_groups"])==1
    @test !isempty(loop["control_flow"]["loops"]["back_edges"])
    @test all(1 in row["dominators"] && row["block"] in row["dominators"] for row in loop["control_flow"]["dominators"]["rows"])
    inputs=[row["id"] for row in loop["slots"] if row["name"]=="value"]
    @test any(row->row["slot"] in inputs && length(row["possible_definitions"])>=2 &&
        all(startswith(id,"definition:") for id in row["possible_definitions"]),loop["slot_flow"]["reads"])
    graph=loop["control_flow"];work=ShenScope.CompilerIRWork(ShenScope.CompilerIRLimits())
    exit=first(graph["return_blocks"])
    witness=ShenScope.compiler_ir_witness(graph,1,exit,work)
    @test witness[1]==1 && witness[end]==exit
    @test all(witness[i+1] in graph["blocks"][witness[i]]["successors"] for i in 1:length(witness)-1)
    handler=compiler_fixture_graph(CompilerIRFixtures.exception,Tuple{Int})
    @test handler["control_flow"]["exception_handlers_present"]
    @test !handler["control_flow"]["all_exception_edges_complete"]
    @test !handler["runtime_execution_observed"]
    @test_throws ShenScopeError compiler_fixture_graph(CompilerIRFixtures.loop,Tuple{Int};limits=ShenScope.CompilerIRLimits(;max_statements=1))
    @test_throws ShenScopeError compiler_fixture_graph(CompilerIRFixtures.loop,Tuple{Int};limits=ShenScope.CompilerIRLimits(;max_flow_operations=1))
    @test_throws ShenScopeError ShenScope.CompilerIRLimits(;max_operands=true)
end

@testset "Trusted compiler frames pin source and reject forged graph projections" begin
    root=ShenScope.runtime_core_root()
    ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    snapshot=runtime_source_snapshot(ctx)
    report=ShenScope.compiler_ir_report("cliptext_string")
    target=ShenScope.compiler_target("cliptext_string")
    normalize(value)=ShenScope.compiler_ir_validate_report(value,target,snapshot)
    @test normalize(parsejson(canonical(report)))["target"]=="cliptext_string"
    @test !report["effects"]["safety_boundary"]
    @test !report["methods"][1]["runtime_execution_observed"]
    corruptions=[
        value->(value["runtime"]["julia_version"]="0.0.0"),
        value->(value["source"]["fingerprint"]=repeat("0",64)),
        value->(value["methods"][1]["identity"]["file"]="../outside.jl"),
        value->(value["methods"][1]["statements"][1]["id"]=true),
        value->(value["methods"][1]["control_flow"]["blocks"][1]["successors"]=[999]),
        value->(value["methods"][1]["statistics"]["statements"]+=1),
        value->(value["methods"][1]["runtime_execution_observed"]=true),
        value->(value["effects"]["safety_boundary"]=true),
        value->(value["methods_truncated"]=0),
        value->(value["methods"][1]["statements"][1]["operand"]["unknown"]=true),
        value->push!(value["methods"][1]["ssa_flow"]["edges"],Dict("definition"=>999,"use"=>1)),
    ]
    for corrupt in corruptions
        value=deepcopy(report);corrupt(value);compiler_fixture_rehash!(value)
        @test_throws ShenScopeError normalize(value)
    end
    wrong=deepcopy(report);wrong["elapsed_seconds"]+=1
    @test_throws ShenScopeError normalize(wrong)
    compared=ShenScope.compiler_ir_compare(report,report)
    @test !compared["source_changed"] && !compared["performance_change_proven"]
    @test all(all(iszero,values(row["statistics_delta"])) for row in compared["methods"])
    @test_throws ShenScopeError ShenScope.compiler_ir_report("Base.eval")
end
