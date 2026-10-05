function problem_fixture(root; session_id="problem-owner", limits=ProblemLimits())
    text = "中😀bad\r\nnext\n"
    write(joinpath(root, "sample.ts"), text)
    ctx = RuntimeContext(root; session_id, state_dir=joinpath(root, "state"),
        permissions=PermissionPolicy(; rules=Dict(:read=>Allow, :process=>Allow, :persistence=>Allow)))
    source = read_workspace_snapshot(ctx, "sample.ts")
    location = SourceRange("sample.ts", 1, 1; start_column=8, end_column=11)
    item = project_problem(source, "error", "wrong value"; location, code=2322, source="fixture")
    file = problem_file_report(source, [item])
    manager = ProblemManager(; limits)
    snapshot = retain_problem_snapshot!(manager, ctx, "fixture", 1, [file]; coverage=Dict("fixture"=>true))
    ctx, manager, source, item, snapshot
end

@testset "Workspace snapshots guard Unicode ranges, symlinks, once approvals and version drift" begin
    mktempdir() do root
        ctx, manager, source, item, snapshot = problem_fixture(root)
        @test source.sha256 == digest("中😀bad\r\nnext\n")
        @test source_editor_range(source.source, item.location) == Dict("start"=>Dict("line"=>0,"character"=>3), "end"=>Dict("line"=>0,"character"=>6))
        @test only(workspace_source_excerpt(source, item.location; context_lines=0)["lines"])["text"] == "中😀bad"
        @test_throws ShenScopeError read_workspace_snapshot(ctx, "../escape")
        @test_throws ShenScopeError project_problem(source, "error", "bad"; location=SourceRange("sample.ts",1,1;start_column=3,end_column=4))
        symlink(joinpath(root,"sample.ts"), joinpath(root,"alias.ts"))
        @test_throws ShenScopeError read_workspace_snapshot(ctx,"alias.ts")
        ctx.permissions.rules[:read]=Ask
        approvals=Ref(0);ctx.approve=request->begin;approvals[]+=1;:once;end
        @test read_workspace_snapshot(ctx,"sample.ts").sha256==source.sha256 && approvals[]==1
        @test_throws ShenScopeError read_workspace_snapshot(ctx,"sample.ts";allow_ask=false)
        ctx.permissions.rules[:read]=Allow
        write(source.absolute,"different\n")
        @test_throws ShenScopeError verify_workspace_snapshot(source,ctx)
        @test_throws ShenScopeError read_workspace_snapshot(ctx,"sample.ts";expected_sha256=source.sha256)
    end
end

@testset "Owned diagnostics withdraw stale markers, compare reports and bound retention" begin
    mktempdir() do root
        ctx, manager, source, item, snapshot = problem_fixture(root)
        @test only(query_problem_snapshot(manager,snapshot.id,ctx)["items"])["id"]==item.id
        @test isempty(query_problem_snapshot(manager,snapshot.id,ctx;query=ProblemQuery(;severity="warning"))["items"])
        @test only(query_problem_snapshot(manager,snapshot.id,ctx;query=ProblemQuery(;text="WRONG"))["items"])["code"]==2322
        projection=project_problem_editor_snapshot(manager,snapshot.id,ctx)
        @test only(projection["files"])["publishable"] && projection["column_unit"]=="utf16" && projection["markers"]==1
        @test projection["requires_editor_buffer_hash_check"] && !projection["complete_project_coverage"]
        foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
        @test_throws ShenScopeError problem_snapshot_read(manager,snapshot.id,foreign)
        @test_throws ShenScopeError project_problem(source,"fatal","bad")
        @test_throws ShenScopeError project_problem(source,"error",repeat("a",17000))
        write(source.absolute,"中😀good\r\nnext\n")
        stale=project_problem_editor_snapshot(manager,snapshot.id,ctx)
        @test only(stale["files"])["freshness"]=="stale" && stale["markers"]==0
        @test isempty(only(problem_snapshot_read(manager,snapshot.id,ctx)["files"])["items"])
        @test length(only(problem_snapshot_read(manager,snapshot.id,ctx;include_stale=true)["files"])["items"])==1
        @test_throws ShenScopeError read_problem_source(manager,snapshot.id,item.id,ctx)
        current=read_workspace_snapshot(ctx,"sample.ts")
        after=retain_problem_snapshot!(manager,ctx,"fixture",2,[problem_file_report(current,ProjectProblem[])])
        compared=compare_problem_snapshots(manager,snapshot.id,after.id,ctx)
        @test compared["removed_total"]==1 && !compared["repair_independently_verified"]
        @test compared["same_file_selection"] && isempty(compared["added"])
        rm(source.absolute)
        @test only(project_problem_editor_snapshot(manager,after.id,ctx)["files"])["freshness"]=="missing"
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError query_problem_snapshot(manager,snapshot.id,ctx)
        @test_throws ShenScopeError compare_problem_snapshots(manager,snapshot.id,after.id,ctx)
        small=ProblemManager(;limits=ProblemLimits(;maximum_snapshots=1))
        first=retain_problem_snapshot!(small,foreign,"fixture",1,ProblemFileReport[])
        second=retain_problem_snapshot!(small,foreign,"fixture",2,ProblemFileReport[])
        @test small.retained_bytes==second.bytes && length(small.snapshots)==1
        @test_throws ShenScopeError ShenScope.owned_problem_snapshot(small,first.id,foreign)
        close_problems!(small)
        @test_throws ShenScopeError retain_problem_snapshot!(small,foreign,"fixture",3,ProblemFileReport[])
    end
end

@testset "Missing and modified compiler configuration invalidates publication" begin
    mktempdir() do root
        ctx, manager, source, item, snapshot=problem_fixture(root)
        absent=retain_problem_snapshot!(manager,ctx,"fixture",1,[problem_file_report(source,[item])];
            configuration=[Dict{String,Any}("path"=>"tsconfig.json","sha256"=>nothing)])
        @test project_problem_editor_snapshot(manager,absent.id,ctx)["markers"]==1
        write(joinpath(root,"tsconfig.json"),"{}")
        @test !project_problem_editor_snapshot(manager,absent.id,ctx)["configuration_current"]
        config=read_workspace_snapshot(ctx,"tsconfig.json")
        configured=retain_problem_snapshot!(manager,ctx,"fixture",2,[problem_file_report(source,[item])];
            configuration=[Dict("path"=>config.path,"sha256"=>config.sha256)])
        write(config.absolute,"{\"strict\":true}")
        @test project_problem_editor_snapshot(manager,configured.id,ctx)["markers"]==0
        @test only(problem_snapshot_read(manager,configured.id,ctx)["files"])["freshness"]=="configuration_stale"
    end
end
