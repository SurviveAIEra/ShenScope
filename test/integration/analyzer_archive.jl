@testset "Analyzer archive, CAS promotion and fresh rollback" begin
    mktempdir() do root
        policy = PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow))
        ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),session_id="archive-owner",permissions=policy)
        manager = AnalyzerManager()
        fixture = AnalyzerTestCase("identity",Dict("value"=>7),Dict(),Dict("value"=>7))
        source = "selftest()=true\nanalyze(data,request)=Dict(\"value\"=>data[\"value\"])"
        first = AnalyzerDefinition("identity",source;tests=[fixture])
        register_analyzer!(manager,first,ctx)
        @test analyzer_archive_list(ctx)["total"] == 0
        @test !isdir(joinpath(ctx.state_dir,"analyzers"))
        archived = archive_analyzer!(manager,"identity",ctx)
        @test archived["archived"] && !archived["validation_at_archive"]
        inventory = analyzer_archive_list(ctx)
        @test inventory["total"] == 1 && !inventory["versions"][1]["active"]
        archive = analyzer_archive(ctx)
        file = ShenScope.analyzer_archive_path(archive,first.name,first.version)
        original = read(file,String)
        @test archive_analyzer!(manager,"identity",ctx)["archived"]
        @test read(file,String) == original
        second_session = RuntimeContext(root;state_dir=ctx.state_dir,session_id="another",permissions=policy)
        restored_manager = AnalyzerManager()
        restored = restore_analyzer!(restored_manager,"identity",second_session;version=first.version)
        @test restored["validation_required"] && restored["validation"] === nothing
        @test restored["definition"]["source_sha256"] == first.source_sha256
        @test analyzer_archive_inspect(ctx,"identity",first.version)["definition"]["source"] == source
        if ShenScope.compute_seccomp_available()
            promoted = promote_analyzer!(manager,"identity",ctx;expected_pointer=0)
            @test promoted["pointer"]["pointer_revision"] == 1
            @test promoted["pointer"]["version"] == first.version
            @test promoted["validation"]["passed"]
            @test read(file,String) == original
            second = AnalyzerDefinition("identity",source*"\n# alternate implementation revision";tests=[fixture])
            register_analyzer!(manager,second,ctx)
            promoted2 = promote_analyzer!(manager,"identity",ctx;version=second.version,expected_pointer=1)
            @test promoted2["pointer"]["pointer_revision"] == 2
            @test promoted2["pointer"]["previous_version"] == first.version
            @test_throws ShenScopeError promote_analyzer!(manager,"identity",ctx;version=first.version,expected_pointer=1)
            @test ShenScope.analyzer_active(archive,"identity",ctx)["version"] == second.version
            rolled = rollback_analyzer!(manager,"identity",first.version,ctx;expected_pointer=2)
            @test rolled["pointer"]["pointer_revision"] == 3
            @test rolled["pointer"]["operation"] == "rollback"
            @test rolled["pointer"]["previous_version"] == second.version
            @test rolled["validation"]["passed"]
            history = analyzer_archive_history(ctx,"identity")
            @test [entry["version"] for entry in history["history"]] == [first.version,second.version,first.version]
            current = restore_analyzer!(AnalyzerManager(),"identity",second_session)
            @test current["definition"]["version"] == first.version
        end
        other_root = joinpath(root,"other");mkdir(other_root)
        other = RuntimeContext(other_root;state_dir=ctx.state_dir,permissions=policy)
        @test analyzer_archive_list(other)["total"] == 0
        @test_throws ShenScopeError ShenScope.analyzer_archive_guard(archive,other)
        @test_throws ShenScopeError analyzer_archive_inspect(other,"identity",first.version)
        user_archived = archive_analyzer!(manager,"identity",ctx;version=first.version,scope=:user)
        @test user_archived["archived"]
        @test analyzer_archive_list(other;scope=:user)["total"] == 1
        user_manager = AnalyzerManager()
        user_restored = restore_analyzer!(user_manager,"identity",other;version=first.version,scope=:user)
        @test user_restored["definition"]["source_sha256"] == first.source_sha256
        @test user_restored["validation_required"] && user_restored["validation"] === nothing
        @test analyzer_archive_list(other)["total"] == 0
        isolated_state = RuntimeContext(other_root;state_dir=joinpath(other_root,"separate-state"),permissions=policy)
        @test analyzer_archive_list(isolated_state;scope=:user)["total"] == 0
        @test_throws ShenScopeError ShenScope.analyzer_archive_guard(analyzer_archive(ctx;scope=:user),isolated_state)
        @test_throws ShenScopeError analyzer_archive_list(ctx;scope=:workspace)
        @test_throws ShenScopeError analyzer_archive_list(ctx;offset=true)
        denied = RuntimeContext(root;state_dir=ctx.state_dir,session_id=ctx.session_id,
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:persistence=>Deny)))
        @test_throws ShenScopeError archive_analyzer!(manager,"identity",denied)
        bad = parsejson(original);bad["definition"]["source"] *= "\n# tampered";write(file,canonical(bad))
        @test_throws ShenScopeError analyzer_archive_inspect(ctx,"identity",first.version)
        write(file,original)
        linked = joinpath(dirname(file),repeat("f",64)*".json");symlink(file,linked)
        @test_throws ShenScopeError analyzer_archive_list(ctx)
        rm(linked)
        expanded = AnalyzerDefinition("capacity_check",source*repeat("\n# capacity fixture",100);tests=[fixture])
        register_analyzer!(manager,expanded,ctx);archive_analyzer!(manager,"capacity_check",ctx)
        small = analyzer_archive(ctx;max_versions=1,max_bytes=1024)
        @test_throws ShenScopeError ShenScope.analyzer_archive_inventory(small,ctx)
        @test isempty(manager.processes.handles) && isempty(ctx.budget.reservations)
    end
end

@testset "Identical computations reuse scoped approvals" begin
    if ShenScope.compute_seccomp_available()
        mktempdir() do root
            categories = Symbol[]
            ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),
                approve=request->(push!(categories,request.category);:session))
            source = "selftest()=true\nanalyze(d,r)=Dict(\"value\"=>d[\"value\"])"
            inputs = [Dict("data"=>Dict("value"=>3),"request"=>Dict())]
            for _ in 1:2
                @test run_isolated_compute(ctx,source,inputs)["results"][1]["value"] == 3
            end
            @test categories == [:dynamic,:process]
        end
    else
        @test_skip "Verified Linux/libseccomp compute sandbox unavailable"
    end
end
