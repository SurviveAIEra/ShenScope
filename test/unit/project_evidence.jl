@testset "Combined evidence retains provider identity and exact declaration anchors" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        snapshot=project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx)
        @test length(snapshot.sources)==2 && length(snapshot.symbols)==5
        @test length(snapshot.relations)==3 && length(snapshot.files)==4
        @test length(snapshot.anchors)==1 && only(values(snapshot.anchors)).eligible_bridge
        a=ShenScope.evidence_symbol_key("go_ast",fixture.ids["a.go"])
        b=ShenScope.evidence_symbol_key("tree_sitter",fixture.ids["a.go"])
        @test a!=b && snapshot.symbols[a].symbol.id==snapshot.symbols[b].symbol.id
        @test Set(source.revision for source in snapshot.sources)==Set([3,7])
        @test only(values(snapshot.anchors)).members==sort([a,b])
        comparison=ShenScope.evidence_compare(snapshot,fixture.args,fixture.ctx)
        row=only(comparison["items"])
        @test row["signature_text_disagreement"] && row["relation_count_disagreement"]==false
        @test !row["winner_selected"] && !row["anchor"]["runtime_equivalence_confirmed"]
        @test comparison["revision_vector"]==Dict("go_ast"=>3,"tree_sitter"=>7)
        @test comparison["summary"]["eligible_bridges"]==1 && !comparison["atomic_multi_source_transaction"]
        results=ShenScope.evidence_search(snapshot,Dict("query"=>"Api","limit"=>1),fixture.ctx)
        @test results["total"]==3 && length(results["items"])==1 && results["next_offset"]==1
        @test only(results["items"])["score_kind"]=="lexical_relevance"
        page=ShenScope.evidence_search(snapshot,Dict("query"=>"Api","limit"=>1,"offset"=>1),fixture.ctx)
        @test only(results["items"])["key"]!=only(page["items"])["key"]
        snapshot.symbols[a].symbol.metadata["signature"]="edited detached observation"
        @test fixture.left.symbols[fixture.ids["a.go"]].metadata["signature"]=="Api()"
        @test !ispath(fixture.left.journal.path) && !ispath(fixture.right.journal.path)
    end
end

@testset "Combined traversal crosses explicit source anchors with inspectable witnesses" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        snapshot=project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx)
        seed=ShenScope.evidence_symbol_key("go_ast",fixture.ids["a.go"])
        request=Dict("evidence_keys"=>[seed])
        impact=analyze(ImpactAnalyzer(),snapshot,request,fixture.ctx)
        rows=impact["items"]
        testrow=only([row for row in rows if row["observation"]["symbol"]["name"]=="TestApi"])
        @test testrow["depth"]==3 && testrow["confidence"]==0.8
        @test [step["step_kind"] for step in testrow["steps"]]==["source_anchor_bridge","provider_relation","provider_relation"]
        @test !testrow["steps"][1]["runtime_equivalence_confirmed"] && !testrow["runtime_execution_confirmed"]
        @test Set(step["backend"] for step in testrow["steps"][2:end])==Set(["tree_sitter"])
        tests=analyze(TestSelectionAnalyzer(),snapshot,request,fixture.ctx)
        @test only(tests["items"])["observation"]["symbol"]["name"]=="TestApi"
        @test !only(tests["items"])["runtime_coverage_confirmed"]
        disabled=project_evidence_snapshot(fixture.states,merge(fixture.args,Dict("include_bridges"=>false)),fixture.ctx)
        isolated=analyze(ImpactAnalyzer(),disabled,request,fixture.ctx)
        @test length(isolated["items"])==1 && only(isolated["items"])["observation"]["symbol"]["name"]=="CallerA"
        depth=project_evidence_snapshot(fixture.states,merge(fixture.args,Dict("max_depth"=>1)),fixture.ctx)
        shallow=analyze(ImpactAnalyzer(),depth,request,fixture.ctx)
        @test !any(row->row["observation"]["symbol"]["name"]=="TestApi",shallow["items"])
        strict=project_evidence_snapshot(fixture.states,merge(fixture.args,Dict("minimum_confidence"=>0.95)),fixture.ctx)
        @test isempty(analyze(ImpactAnalyzer(),strict,request,fixture.ctx)["items"])
        whole=project_evidence_snapshot(fixture.states,merge(fixture.args,Dict("action"=>"evidence_impact","paths"=>["a.go"])),fixture.ctx)
        @test length(whole.files)==4
        @test any(row->row["observation"]["symbol"]["name"]=="TestApi",analyze(ImpactAnalyzer(),whole,Dict("paths"=>["a.go"]),fixture.ctx)["items"])
    end
end

@testset "Ambiguous or shifted declarations are not silently bridged" begin
    for options in ((duplicate=true,),(shifted=true,))
        mktempdir() do root
            fixture=evidence_fixture(root;options...)
            snapshot=project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx)
            @test isempty(snapshot.anchors) || !only(values(snapshot.anchors)).eligible_bridge
            seed=ShenScope.evidence_symbol_key("go_ast",fixture.ids["a.go"])
            impact=analyze(ImpactAnalyzer(),snapshot,Dict("evidence_keys"=>[seed]),fixture.ctx)
            @test only(impact["items"])["observation"]["symbol"]["name"]=="CallerA"
        end
    end
end

@testset "Combined evidence refuses conflicting hashes and changing revisions" begin
    mktempdir() do root
        fixture=evidence_fixture(root;mismatch=true)
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx))==:evidence_conflict
    end
    mktempdir() do root
        fixture=evidence_fixture(root)
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,merge(fixture.args,Dict("source_revisions"=>Dict("go_ast"=>2))),fixture.ctx))==:conflict
        snapshot=project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx)
        fixture.left.revision+=1
        @test evidence_error_code(()->ShenScope.evidence_verify_snapshot(snapshot,fixture.states,fixture.ctx))==:conflict
        fixture.left.revision-=1
        write(joinpath(root,"a.go"),"package changed\n")
        @test evidence_error_code(()->ShenScope.evidence_verify_snapshot(snapshot,fixture.states,fixture.ctx))==:stale_index
    end
end

@testset "Evidence capture and analysis share cancellation, permissions and bounds" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        for extra in (Dict("max_symbols"=>2),Dict("max_relations"=>1))
            @test evidence_error_code(()->project_evidence_snapshot(fixture.states,merge(fixture.args,extra),fixture.ctx))==:capacity
        end
        for extra in (Dict("backends"=>["go_ast","go_ast"]),Dict("max_depth"=>true),
                Dict("minimum_confidence"=>NaN),Dict("include_bridges"=>1),Dict("source_revisions"=>Dict("tree_sitter"=>true)))
            @test evidence_error_code(()->project_evidence_snapshot(fixture.states,merge(fixture.args,extra),fixture.ctx)) in (:arguments,:graph_query)
        end
        cancelled=child_context(fixture.ctx);cancel!(cancelled.cancellation)
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,fixture.args,cancelled))==:cancelled
        denied=RuntimeContext(root;state_dir=fixture.ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,fixture.args,denied))==:permission
        expired=RuntimeContext(root;state_dir=fixture.ctx.state_dir,permissions=fixture.ctx.permissions)
        expired.budget.started_ns=time_ns()-UInt64(4000*10^9)
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,fixture.args,expired))==:budget
    end
end

@testset "Evidence bounds source ranges and rejects empty declaration bridges" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        old=fixture.left.symbols[fixture.ids["a.go"]]
        invalid=CodeSymbol(old.id,old.kind,old.name,old.qualified_name,SourceRange("a.go",99,99),old.language,old.metadata)
        facts=fixture.left.files["a.go"]
        fixture.left.files["a.go"]=FileFacts(facts.path,facts.sha256,[invalid],facts.relations,facts.references,facts.diagnostics)
        fixture.left.symbols[old.id]=invalid
        @test evidence_error_code(()->project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx))==:source_position
    end
    mktempdir() do root
        fixture=evidence_fixture(root)
        for state in fixture.states
            old=state.symbols[fixture.ids["a.go"]]
            empty=CodeSymbol(old.id,old.kind,old.name,old.qualified_name,SourceRange("a.go",2,2),old.language,old.metadata)
            facts=state.files["a.go"]
            state.files["a.go"]=FileFacts(facts.path,facts.sha256,[empty],facts.relations,facts.references,facts.diagnostics)
            state.symbols[old.id]=empty
        end
        @test isempty(project_evidence_snapshot(fixture.states,fixture.args,fixture.ctx).anchors)
    end
end
