include("../fixtures/semantic_transport.jl")
@testset "Actual TypeScript diagnostics become current-source editor markers and retract after edits" begin
    mktempdir() do root
        write(joinpath(root,"bad.ts"),"export const wrong: number = \"bad\";\n")
        ctx=semantic_context(root);backend=TypeScriptSemanticBackend();manager=ProblemManager()
        try
            state=build!(backend,ctx)
            first=capture_indexed_problems!(manager,state,ctx)
            results=query_problem_snapshot(manager,first.id,ctx)
            @test any(item->item["code"]==2322 && item["semantic"],results["items"])
            projection=project_problem_editor_snapshot(manager,first.id,ctx)
            @test projection["markers"]>=1 && only(projection["files"])["source_sha256"]==digest(read(joinpath(root,"bad.ts"),String))
            write(joinpath(root,"bad.ts"),"export const wrong: number = 42;\n")
            @test project_problem_editor_snapshot(manager,first.id,ctx)["markers"]==0
            @test_throws ShenScopeError capture_indexed_problems!(manager,state,ctx)
            update!(backend,state,["bad.ts"],ctx)
            second=capture_indexed_problems!(manager,state,ctx;expected_revision=state.revision)
            @test isempty(query_problem_snapshot(manager,second.id,ctx)["items"])
            @test compare_problem_snapshots(manager,first.id,second.id,ctx)["removed_total"]>=1
            @test !project_problem_editor_snapshot(manager,second.id,ctx)["complete_project_coverage"]
            @test_throws ShenScopeError capture_indexed_problems!(manager,state,ctx;expected_revision=state.revision-1)
        finally
            backend_close!(backend)
        end
    end
end
