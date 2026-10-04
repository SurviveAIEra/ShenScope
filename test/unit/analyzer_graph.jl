function analyzer_graph_fixture(root;state_dir=joinpath(root,"state"))
    ctx = RuntimeContext(root;state_dir,
        permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow)))
    state = ProjectState(ctx,GoASTBackend())
    write(joinpath(root,"sample.go"),"package sample\n")
    one = ShenScope.symbol_id("one");two = ShenScope.symbol_id("two");three = ShenScope.symbol_id("three")
    for (id,name) in ((one,"one"),(two,"two"),(three,"three"))
        state.symbols[id] = CodeSymbol(id,:function,name,name,SourceRange("sample.go",1,1),:go,Dict())
    end
    edge = Relation(one,two,:calls,SourceRange("sample.go",1,1);confidence=0.5)
    state.relations[edge.id] = edge
    state.forward[one] = Set([edge.id]);state.reverse[two] = Set([edge.id])
    state.files["sample.go"] = FileFacts("sample.go",digest("package sample\n"),collect(values(state.symbols)),[edge],CallReference[],Dict{String,Any}[])
    (ctx=ctx,state=state,one=one,two=two,three=three,edge=edge)
end

@testset "Parent-owned analyzer graph evidence and freshness" begin
    mktempdir() do root
        f = analyzer_graph_fixture(root)
        snapshot = ShenScope.analyzer_graph_snapshot(f.state,Dict(),f.ctx)
        @test snapshot.revision == 0 && length(snapshot.symbols) == 3
        candidate = Dict("symbol_id"=>f.one.value,"score"=>0.8,"confidence"=>0.5,"reason"=>"Recorded caller","evidence"=>[f.edge.id])
        result = ShenScope.analyzer_graph_result(snapshot,Dict("candidates"=>[candidate]))
        @test result["candidates"][1]["symbol"]["name"] == "one"
        @test result["candidates"][1]["relation_evidence"][1]["id"] == f.edge.id
        @test result["candidates"][1]["claim_status"] == "hypothesis_with_recorded_evidence"
        for change in (Dict("symbol_id"=>repeat("f",32)),Dict("score"=>NaN),Dict("confidence"=>0.6),
                Dict("confidence"=>true),Dict("evidence"=>[repeat("f",64)]),Dict("evidence"=>[f.edge.id,f.edge.id]),
                Dict("symbol_id"=>f.three.value),Dict("location"=>Dict("file"=>"../escape")))
            @test_throws ShenScopeError ShenScope.analyzer_graph_result(snapshot,Dict("candidates"=>[merge(candidate,change)]))
        end
        @test_throws ShenScopeError ShenScope.analyzer_graph_result(snapshot,Dict("candidates"=>[candidate,candidate]))
        @test_throws ShenScopeError ShenScope.analyzer_graph_result(snapshot,Dict("candidates"=>[merge(candidate,Dict("evidence"=>Any[]))]))
        unsupported = merge(candidate,Dict("evidence"=>Any[],"confidence"=>0))
        @test ShenScope.analyzer_graph_result(snapshot,Dict("candidates"=>[unsupported]))["candidates"][1]["confidence"] == 0
        partial = ShenScope.analyzer_graph_snapshot(f.state,Dict("symbols"=>[f.two.value],"max_depth"=>1),f.ctx)
        @test length(partial.symbols) == 2 && partial.data["scope"] == "neighborhood"
        @test ShenScope.analyzer_graph_result(partial,Dict("candidates"=>[candidate]))["candidates"][1]["seed_connected"]
        @test_throws ShenScopeError ShenScope.analyzer_graph_snapshot(f.state,Dict("max_symbols"=>2),f.ctx)
        @test_throws ShenScopeError ShenScope.analyzer_graph_snapshot(f.state,Dict("max_symbols"=>true),f.ctx)
        @test_throws ShenScopeError ShenScope.analyzer_graph_snapshot(f.state,Dict("direction"=>"any"),f.ctx)
        @test ShenScope.analyzer_graph_current!(snapshot,f.state,f.ctx) === nothing
        f.state.revision += 1
        @test_throws ShenScopeError ShenScope.analyzer_graph_current!(snapshot,f.state,f.ctx)
        f.state.revision = 0;f.state.metadata["changed"] = true
        @test_throws ShenScopeError ShenScope.analyzer_graph_current!(snapshot,f.state,f.ctx)
        @test contract_report(IsolatedJuliaAnalyzer)["valid"]
    end
end
