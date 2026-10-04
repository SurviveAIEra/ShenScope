@testset "Julia dispatch reports syntax patterns and refuses stale or unbounded evidence" begin
    mktempdir() do root
        ctx=julia_project_context(root)
        write(joinpath(root,"a.jl"),"module Demo\nf(x::Int,y)=x\nf(x,y::Int)=y\nf(x::Int,y)=2x\nf(x,y,z)=z\nend\n")
        state=build!(JuliaSyntaxBackend(),ctx)
        result=ShenScope.julia_project_query(state,Dict("action"=>"julia_dispatch","query"=>"Demo.f"),ctx)
        group=only(result["items"])
        @test group["method_count"]==4 && group["pairs_considered"]==6
        @test length(group["pairs"])==3
        @test count(pair->pair["classification"]=="crossed_annotation_pattern",group["pairs"])==2
        @test count(pair->pair["classification"]=="same_syntax_signature",group["pairs"])==1
        @test all(pair->pair["runtime_ambiguity"]===nothing && pair["runtime_overwrite"]===nothing,group["pairs"])
        @test !result["compiler_confirmed"] && !result["source_evaluated"]
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_dispatch","max_pairs"=>2),ctx))==:graph_query
        page=ShenScope.julia_project_query(state,Dict("action"=>"julia_methods","limit"=>1),ctx)
        @test length(page["items"])==1 && page["total"]==4 && page["next_offset"]==1
        next=ShenScope.julia_project_query(state,Dict("action"=>"julia_methods","limit"=>1,"offset"=>1),ctx)
        @test only(page["items"])["id"]!=only(next["items"])["id"]
        @test isempty(ShenScope.julia_project_query(state,Dict("action"=>"julia_methods","file"=>"missing.jl"),ctx)["items"])
        structure=only(ShenScope.julia_project_query(state,Dict("action"=>"julia_structure"),ctx)["items"])
        @test structure["file"]=="a.jl" && length(structure["declarations"])==5
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_methods","revision"=>0),ctx))==:conflict
        other=ProjectState(ctx,GoASTBackend())
        @test julia_project_error(()->ShenScope.julia_project_query(other,Dict("action"=>"julia_methods"),ctx))==:capability
        expired=julia_project_context(root);expired.budget.started_ns=time_ns()-UInt64(4000*10^9)
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_methods"),expired))==:budget
        cancelled=julia_project_context(root);cancel!(cancelled.cancellation)
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_methods"),cancelled))==:cancelled
        denied=julia_project_context(root;rules=Dict(:read=>Deny))
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_methods"),denied))==:permission
        write(joinpath(root,"a.jl"),"f(x)=x\n")
        @test julia_project_error(()->ShenScope.julia_project_query(state,Dict("action"=>"julia_methods"),ctx))==:stale_index
        delta=update!(JuliaSyntaxBackend(),state,["a.jl"],ctx)
        @test delta.changed_files==["a.jl"] && state.revision==2
        @test only(ShenScope.julia_project_query(state,Dict("action"=>"julia_methods"),ctx)["items"])["qualified_name"]=="f"
    end
end

@testset "Dispatch type trivia preserves distinct literal annotations" begin
    mktempdir() do root
        ctx=julia_project_context(root)
        write(joinpath(root,"literal.jl"),"f(x::Val{\"a b\"})=x\nf(x::Val{\"ab\"})=x\n")
        state=build!(JuliaSyntaxBackend(),ctx)
        result=ShenScope.julia_project_query(state,Dict("action"=>"julia_dispatch"),ctx)
        pair=only(only(result["items"])["pairs"])
        @test pair["classification"]=="unresolved_type_overlap"
        @test only(pair["axes"])["pattern"]=="different_annotations_unresolved"
        @test only(pair["axes"])["left"]=="Val{\"a b\"}"
        @test only(pair["axes"])["right"]=="Val{\"ab\"}"
    end
end
