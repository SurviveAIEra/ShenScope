@testset "Real Git history preserves NUL paths, binaries, empty commits and shallow coverage" begin
    mktempdir() do root
        ids, special = history_fixture_repository(root)
        ctx = history_fixture_context(root)
        snapshot = git_history_snapshot(ctx;limits=GitHistoryLimits(;bulk_threshold=2))
        @test snapshot.head == last(ids) && length(snapshot.commits) == 7 && !snapshot.shallow
        @test snapshot.git_version == history_fixture_git(root,"--version";capture=true)
        @test isempty(snapshot.commits[3].changes)
        @test only(snapshot.commits[2].changes).added === nothing
        @test Set(change.path for change in snapshot.commits[1].changes) == Set([special,"renamed 中文.jl"])
        @test !git_history_coverage(snapshot)["working_tree_included"] && git_history_coverage(snapshot)["bulk_commits_excluded"] == 1
        @test git_history_coverage(snapshot)["rename_mode"] == "delete_and_add"
        limited = git_history_snapshot(ctx;limits=GitHistoryLimits(;commits=2))
        @test limited.limit_reached && [commit.id for commit in limited.commits] == reverse(ids[6:7])
        stats = ShenScope.history_file_statistics(snapshot,ctx)
        @test stats["a.jl"].ordinals == [4,6] && stats["b.jl"].ordinals == [4,5,6]
        @test stats["a.jl"].bulk_changes == 1 && stats["binary.bin"].binary_changes == 1
        write(joinpath(root,".git","shallow"), ids[6]*"\n")
        shallow = git_history_snapshot(ctx)
        @test shallow.shallow && length(shallow.commits) == 2 && isempty(last(shallow.commits).parents)
        rm(joinpath(root,".git","shallow"))
        for index in 1:20; write(joinpath(root,repeat("long",16)*string(index)*".txt"),"capacity fixture\n"); end
        push!(ids,history_fixture_commit(root))
        @test_throws ShenScopeError git_history_snapshot(ctx;limits=GitHistoryLimits(;output_bytes=1024))
        withenv("GIT_DIR"=>joinpath(root,"outside"), "GIT_CONFIG_COUNT"=>"1", "GIT_CONFIG_KEY_0"=>"alias.log",
                "GIT_CONFIG_VALUE_0"=>"!exit 99", "LD_PRELOAD"=>"/not/a/library") do
            @test git_history_snapshot(ctx).head == last(ids)
            env = ShenScope.git_history_environment()
            @test !haskey(env,"GIT_DIR") && !haskey(env,"LD_PRELOAD") && env["GIT_CONFIG_COUNT"] == "0"
        end
        @test_throws ShenScopeError git_history_snapshot(history_fixture_context(root;permissions=PermissionPolicy(;rules=Dict(:read=>Deny,:process=>Allow))))
        @test_throws ShenScopeError git_history_snapshot(history_fixture_context(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Deny))))
        canceled = history_fixture_context(root);cancel!(canceled.cancellation)
        @test_throws ShenScopeError git_history_snapshot(canceled)
        budget = BudgetLedger(BudgetLimits(;max_seconds=0.001));sleep(0.01)
        @test_throws ShenScopeError git_history_snapshot(history_fixture_context(root;budget))
        config = joinpath(root,".git","config");original=read(config,String)
        write(config,original*"\n[include]\n path = /outside/config\n")
        @test_throws ShenScopeError git_history_snapshot(ctx)
        write(config,original)
        write(joinpath(root,".git","objects","info","alternates"),"/outside/objects\n")
        @test_throws ShenScopeError git_history_snapshot(ctx)
        rm(joinpath(root,".git","objects","info","alternates"))
        mktempdir() do stranger
            symlink(joinpath(root,".git"),joinpath(stranger,".git"))
            @test_throws ShenScopeError git_history_snapshot(history_fixture_context(stranger))
        end
    end
end

@testset "Co-change and review risk join a fixed project revision with exact commit evidence" begin
    mktempdir() do root
        ids, _ = history_fixture_repository(root)
        ctx = history_fixture_context(root)
        state = build!(HistoryFixtureBackend(),ctx)
        request = Dict{String,Any}("paths"=>["a.jl"],"bulk_threshold"=>2,"minimum_support"=>2)
        result = analyze(GitCochangeAnalyzer(),state,request,ctx)
        candidate = only(result["candidates"])
        @test candidate["file"] == "b.jl" && candidate["joint_commits"] == 2
        @test candidate["score"] ≈ 0.4 && candidate["confidence"] ≈ 0.5
        @test [entry["commit"] for entry in candidate["evidence"]] == [ids[4],ids[2]]
        @test candidate["associations"][1]["conditional_frequency"] == 1.0
        one_commit = analyze(GitCochangeAnalyzer(),state,Dict("paths"=>["b.jl"],"bulk_threshold"=>2,"minimum_support"=>1),ctx)
        @test any(entry -> entry["file"] == "c.jl" && entry["joint_commits"] == 1, one_commit["candidates"])
        @test result["coverage"]["head"] == last(ids) && result["revision"] == state.revision
        @test result["coverage"]["index_matches_head"] == "not_checked"
        id = state.files["a.jl"].symbols[1].id.value
        symbolic = analyze(GitCochangeAnalyzer(),state,Dict("symbols"=>[id],"bulk_threshold"=>2),ctx)
        @test symbolic["candidates"] == result["candidates"]
        @test_throws ShenScopeError analyze(GitCochangeAnalyzer(),state,Dict(),ctx)
        @test_throws ShenScopeError analyze(GitCochangeAnalyzer(),state,Dict("paths"=>["missing.jl"]),ctx)
        @test_throws ShenScopeError analyze(RiskAnalyzer(),state,Dict("revision"=>state.revision+1),ctx)
        risk = analyze(RiskAnalyzer(),state,Dict("bulk_threshold"=>2,"limit"=>2),ctx)
        @test risk["truncated"] && length(risk["candidates"]) == 2 && risk["total_candidates"] == 4
        @test !risk["scoring"]["calibrated"] && all(entry -> 0 <= entry["score"] <= 1,risk["candidates"])
        selected = analyze(RiskAnalyzer(),state,Dict("paths"=>["a.jl"],"bulk_threshold"=>2),ctx)
        @test only(selected["candidates"])["metrics"]["incoming_files"] == 1
        @test only(selected["candidates"])["metrics"]["added_lines"] == 2
        @test only(selected["candidates"])["risk_kind"] == "heuristic_review_priority"
        snapshot = ShenScope.history_index_snapshot(state,Dict(),ctx)
        state.revision += 1
        @test_throws ShenScopeError ShenScope.verify_history_index(snapshot,state,ctx)
    end
end

@testset "History approval boundaries reject declaration changes, expired waits and moved HEAD" begin
    mktempdir() do root
        history_fixture_repository(root)
        rules = Dict(:read=>Allow,:process=>Ask,:network=>Deny)
        requests = Ref(0)
        approval = request -> begin
            requests[] += 1
            requests[] == 5 && history_fixture_commit(root)
            :once
        end
        ctx = history_fixture_context(root;permissions=PermissionPolicy(;rules),approve=approval)
        @test_throws ShenScopeError git_history_snapshot(ctx)
        @test requests[] == 5
        changed = history_fixture_context(root;permissions=PermissionPolicy(;rules),approve=request -> begin
            open(io -> write(io,"\n"),joinpath(root,".git","config"),"a");:once
        end)
        @test_throws ShenScopeError git_history_snapshot(changed)
        expired = history_fixture_context(root;permissions=PermissionPolicy(;rules),approve=request -> (sleep(0.08);:once))
        @test_throws ShenScopeError git_history_snapshot(expired;limits=GitHistoryLimits(;timeout_seconds=0.05))
        denied = history_fixture_context(root;permissions=PermissionPolicy(;rules),approve=request -> :deny)
        @test_throws ShenScopeError git_history_snapshot(denied)
        canceled = history_fixture_context(root;permissions=PermissionPolicy(;rules),approve=request -> begin
            cancel!(ShenScope.current_context().cancellation);:once
        end)
        @test_throws ShenScopeError git_history_snapshot(canceled)
    end
end
