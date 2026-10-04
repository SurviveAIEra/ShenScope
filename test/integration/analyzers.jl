@testset "External analyzer tests are checked by Core" begin
    if !ShenScope.compute_seccomp_available()
        @test_skip "Verified Linux/libseccomp compute sandbox unavailable"
    else
        mktempdir() do root
            ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow)))
            manager = AnalyzerManager()
            source = "selftest()=true\nanalyze(d,r)=Dict(\"total\"=>sum(d[\"values\"]))"
            fixture = AnalyzerTestCase("known sum",Dict("values"=>[2,3]),Dict(),Dict("total"=>5))
            definition = AnalyzerDefinition("sum",source;tests=[fixture])
            register_analyzer!(manager,definition,ctx)
            result = evaluate_analyzer!(manager,"sum",Dict("values"=>[3,4,5]),Dict(),ctx)
            @test result["result"] == Dict("total"=>12)
            @test result["validation"]["external_tests"]["passed"]
            @test result["validation"]["external_tests"]["receipts"][1]["actual_sha256"] == digest(canonical(Dict("total"=>5)))
            @test result["validation"]["sandbox"]["filesystem_write"] == false
            @test analyzer_inspect(manager,"sum",ctx)["validation"]["passed"]
            dishonest = AnalyzerDefinition("wrong", "selftest()=true\nanalyze(d,r)=Dict(\"total\"=>99)";tests=[fixture])
            register_analyzer!(manager,dishonest,ctx)
            checked = validate_analyzer!(manager,"wrong",ctx)
            @test !checked["passed"] && checked["selftest"]
            @test !checked["external_tests"]["receipts"][1]["passed"]
            @test analyzer_inspect(manager,"wrong",ctx)["failure"] !== nothing
            @test_throws ShenScopeError evaluate_analyzer!(manager,"wrong",Dict("values"=>[1]),Dict(),ctx)
            @test analyzer_inspect(manager,"wrong",ctx)["validation"] === nothing
            @test isempty(manager.processes.handles) && isempty(ctx.budget.reservations)
            @test all(record -> isempty(record.running),values(manager.records))
        end
    end
end
