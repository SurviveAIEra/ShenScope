@testset "Shared iterative graph condensation matches independent reachability" begin
    nodes=["n"*string(index) for index in 1:16]
    for variant in 1:8
        edges=Tuple{String,String}[(source,target) for (i,source) in enumerate(nodes) for (j,target) in enumerate(nodes)
            if mod(i*29+j*17+variant*11,31)<variant]
        forward,reverse=migration_adjacency(nodes,edges)
        actual=ShenScope.strongly_connected_groups(forward,reverse)
        reach=Dict(node=>migration_reachability(forward,node) for node in nodes)
        expected=unique([sort!([other for other in nodes if other in reach[node] && node in reach[other]]) for node in nodes])
        sort!(expected;by=first)
        @test actual==expected
        rebuilt_forward,rebuilt_reverse=migration_adjacency(reverse!(copy(nodes)),reverse!(copy(edges)))
        @test ShenScope.strongly_connected_groups(rebuilt_forward,rebuilt_reverse)==actual
    end
    forward,reverse=migration_adjacency(["a","b"],[("a","b")])
    @test_throws ShenScopeError ShenScope.strongly_connected_groups(forward,reverse;max_edges=0)
    empty!(reverse["b"])
    @test_throws ShenScopeError ShenScope.strongly_connected_groups(forward,reverse)
    @test_throws ShenScopeError ShenScope.dependency_layers(Dict("a"=>Set(["b"]),"b"=>Set(["a"])))
    @test_throws ShenScopeError ShenScope.dependency_layers(Dict("a"=>Set(["missing"])))
    @test ShenScope.dependency_layers(Dict("a"=>Set{String}(),"b"=>Set(["a"]),"c"=>Set(["a"])))==[["a"],["b","c"]]
    forward,reverse=migration_adjacency(nodes,[(nodes[index],nodes[index+1]) for index in 1:15])
    called=Ref(0)
    @test_throws ShenScopeError ShenScope.strongly_connected_groups(forward,reverse;checkpoint=()->begin
        called[]+=1;called[]>10 && throw(ShenScopeError(:cancelled,"fixture cancellation"))
    end)
    @test called[]==11
end

@testset "Migration batches preserve dependency order, cycles and evidence" begin
    mktempdir() do root
        fixture=migration_fixture(root;cycle=true)
        ctx=fixture.ctx;state=fixture.state
        request=Dict{String,Any}("paths"=>["a.jl"])
        result=analyze(MigrationAnalyzer(),state,request,ctx)
        @test result["status"]=="review_proposal" && !result["truncated"]
        @test !result["writes_performed"] && !result["tests_executed"] && !result["execution_registered"]
        @test result["cycle_groups"]==1 && result["total_steps"]==4
        @test only(first(result["steps"])["files"])["path"]=="a.jl"
        cyclic=only(step for step in result["steps"] if step["atomic_group"])
        @test [file["path"] for file in cyclic["files"]]==["b.jl","c.jl"] && cyclic["layer"]==2
        @test cyclic["compatibility_review_required"] && cyclic["manual_review_required"]
        @test all(edge -> edge["minimum_confidence"]==0.8,cyclic["dependencies"])
        @test all(evidence -> evidence["provenance"]=="synthetic_fixture",[evidence for edge in cyclic["dependencies"] for evidence in edge["evidence"]])
        @test first(last(result["steps"])["test_candidates"])["name"]=="TestCaller"
        positions=Dict(step["id"]=>step["layer"] for step in result["steps"])
        @test all(step -> all(id -> positions[id]<step["layer"],step["depends_on"]),result["steps"])
        @test analyze(MigrationAnalyzer(),state,request,ctx)["plan_id"]==result["plan_id"]
        reversed=analyze(MigrationAnalyzer(),state,merge(request,Dict("order"=>"callers_first")),ctx)
        @test only(last(reversed["steps"])["files"])["path"]=="a.jl" && reversed["plan_id"]!=result["plan_id"]
        behavior=analyze(MigrationAnalyzer(),state,merge(request,Dict("change_kind"=>"behavior")),ctx)
        @test all(step -> !step["compatibility_review_required"],behavior["steps"])
        filtered=analyze(MigrationAnalyzer(),state,merge(request,Dict("minimum_confidence"=>0.9)),ctx)
        @test filtered["coverage"]["file_dependencies"]==0 && filtered["coverage"]["relations_excluded_by_confidence"]==5
        partial=analyze(MigrationAnalyzer(),state,merge(request,Dict("max_depth"=>0)),ctx)
        @test partial["truncated"] && partial["status"]=="partial_proposal" && partial["coverage"]["selected_files"]==1
        capped=analyze(MigrationAnalyzer(),state,merge(request,Dict("limit"=>1)),ctx)
        @test capped["truncated"] && capped["omitted_steps"]==3 && capped["plan_id"]==result["plan_id"]
        @test_throws ShenScopeError analyze(MigrationAnalyzer(),state,merge(request,Dict("max_files"=>1)),ctx)
        @test_throws ShenScopeError analyze(MigrationAnalyzer(),state,merge(request,Dict("revision"=>2)),ctx)
        @test_throws ShenScopeError analyze(MigrationAnalyzer(),state,Dict(),ctx)
        @test_throws ShenScopeError analyze(MigrationAnalyzer(),state,Dict("symbols"=>[repeat("f",32)]),ctx)
        @test analyze(ArchitectureAnalyzer(),state,Dict(),ctx)["cycles"]==[["b.jl","c.jl"]]
        @test graph_traverse(state,[fixture.ids["a.jl"]];max_depth=0,ctx)["truncated"]
        @test graph_traverse(state,[fixture.ids["a.jl"]];max_depth=1,ctx)["truncated"]
        @test !graph_traverse(state,[fixture.ids["a.jl"]];max_depth=8,ctx)["truncated"]
        graph=ShenScope.migration_graph(state,request,MigrationOptions(),ctx)
        state.revision+=1
        @test_throws ShenScopeError ShenScope.analyzer_graph_current!(graph.snapshot,state,ctx)
        state.revision-=1
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError analyze(MigrationAnalyzer(),state,request,ctx)
    end
end

@testset "Migration limits and CLI intent remain strict" begin
    for options in ((;change_kind=:unknown),(;order=:random),(;max_files=true),(;max_depth=-1),
            (;max_relations=100001),(;minimum_confidence=NaN),(;minimum_confidence=true),(;minimum_confidence=1.1))
        @test_throws ShenScopeError MigrationOptions(;options...)
    end
    positional,flags=ShenScope.parse_cli(["project","migration","中😀.jl","--change-kind","rename","--order","callers_first",
        "--max-depth","2","--max-files","8","--minimum-confidence","0.5","--revision","1"])
    args=ShenScope.cli_project_arguments(positional,flags)
    ShenScope.validate_tool_arguments(ProjectTool(),args)
    @test args["paths"]==["中😀.jl"] && args["change_kind"]=="rename" && args["order"]=="callers_first"
    @test args["max_depth"]==2 && args["max_files"]==8 && args["minimum_confidence"]==0.5 && args["revision"]==1
    for pair in (("--max-depth","x"),("--minimum-confidence","NaN"))
        @test_throws ShenScopeError begin
            p,f=ShenScope.parse_cli(["project","migration","a.jl",pair...]);ShenScope.cli_project_arguments(p,f)
        end
    end
end
