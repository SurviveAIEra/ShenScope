@testset "Bounded multi-language discovery reads declarations and owns catalogs" begin
    mktempdir() do root
        ctx=project_testing_context(root);manager=ProjectTestManager(;max_catalogs=2)
        markers=Dict("node/package.json"=>"{\"scripts\":{\"test\":\"touch must-not-run.txt\"}}",
            "python/pyproject.toml"=>"[tool.pytest.ini_options]\naddopts='-q'\n",
            "go/go.mod"=>"module example.invalid/app\n", "rust/Cargo.toml"=>"[package]\nname='app'\nversion='0.1.0'\n",
            "c/CMakeLists.txt"=>"enable_testing()\n", "generic/Makefile"=>"test:\n\tfalse\n",
            "java/pom.xml"=>"<project/>\n", "kotlin/build.gradle.kts"=>"plugins {}\n",
            "dotnet/app.csproj"=>"<Project/>\n", "php/composer.json"=>"{\"scripts\":{\"test\":[\"runner\"]}}",
            "ruby/Rakefile"=>"task :test\n", "julia/Project.toml"=>"name='Fixture'\n")
        for (path,text) in markers;mkpath(dirname(joinpath(root,path)));write(joinpath(root,path),text);end
        mkpath(joinpath(root,"node_modules","ignored"));write(joinpath(root,"node_modules","ignored","package.json"),"{}")
        mkpath(ctx.state_dir);write(joinpath(ctx.state_dir,"package.json"),"{}")
        write(joinpath(root,"invalid.json"),"{}");mkpath(joinpath(root,"invalid"));write(joinpath(root,"invalid","package.json"),"{no}")
        symlink(joinpath(root,"node"),joinpath(root,"linked"))
        catalog=discover_project_tests!(manager,ctx)
        @test length(catalog["candidates"])==12
        @test Set(candidate["language"] for candidate in catalog["candidates"])==Set([
            "javascript/typescript","python","go","rust","c/c++","any","java/jvm","java/kotlin/jvm","c#/f#/dotnet","php","ruby","julia"])
        @test catalog["coverage"]["skipped_symlinks"]==1 && catalog["coverage"]["pruned_directories"]>=2
        @test catalog["coverage"]["status"]=="partial" && length(catalog["coverage"]["invalid_markers"])==1
        @test !catalog["coverage"]["complete_project_inventory"] && !isfile(joinpath(root,"node","must-not-run.txt"))
        @test read_project_test_catalog(manager,catalog["catalog_id"],ctx)==catalog
        changed=deepcopy(catalog);changed["candidates"][1]["argv"][1]="different"
        @test read_project_test_catalog(manager,catalog["catalog_id"],ctx)["candidates"][1]["argv"]!=changed["candidates"][1]["argv"]
        foreign=project_testing_context(root)
        @test_throws ShenScopeError read_project_test_catalog(manager,catalog["catalog_id"],foreign)
        other_state=RuntimeContext(root;session_id=ctx.session_id,state_dir=joinpath(root,"other-state"),permissions=ctx.permissions)
        @test_throws ShenScopeError read_project_test_catalog(manager,catalog["catalog_id"],other_state)
        @test_throws ShenScopeError discover_project_tests!(manager,ctx;scopes=["linked"])
        @test_throws ShenScopeError discover_project_tests!(manager,ctx;scopes=[ctx.state_dir])
        @test_throws ShenScopeError discover_project_tests!(manager,ctx;scopes=[".."])
        @test_throws ShenScopeError ProjectTestDiscoveryLimits(;files=true)
        @test_throws ShenScopeError ProjectTestDiscoveryLimits(;marker_bytes=1024,total_marker_bytes=64)
        partial=discover_project_tests!(manager,ctx;limits=ProjectTestDiscoveryLimits(;files=1,depth=0))
        @test !isempty(partial["coverage"]["limits_hit"]) && partial["coverage"]["status"]=="partial"
        next=discover_project_tests!(manager,ctx;scopes=["go"])
        @test length(next["candidates"])==1
        @test_throws ShenScopeError read_project_test_catalog(manager,catalog["catalog_id"],ctx)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError discover_project_tests!(manager,ctx)
        cleanup_project_tests!(manager)
    end
end

@testset "Framework reports retain counts, cases, malformed records and safe source references" begin
    mktempdir() do root
        ctx=project_testing_context(root)
        parse(format,out,err="")=ShenScope.parse_project_test_output(format,out,err,ctx,root)
        python=parse("unittest","","test_add (test_calc.Addition.test_add) ... FAIL\ntest_skip (test_calc.Addition.test_skip) ... skipped 'later'\n  File \""*joinpath(root,"test_calc.py")*"\", line 4, in test_add\nRan 2 tests in 0.012s\nFAILED (failures=1, skipped=1)\n")
        @test python["observed_case_counts"]["failed"]==1 && python["observed_case_counts"]["skipped"]==1
        @test python["framework_summary"]["tests"]==2 && python["framework_summary"]["failures"]==1
        @test python["frames"][1]["path"]=="test_calc.py" && python["frames"][1]["line"]==4
        @test !python["case_results_independently_verified"] && !python["complete_project_coverage"]
        tap=parse("tap","TAP version 13\n    not ok 1 - nested\nnot ok 1 - addition\nok 2 - unsupported # SKIP reason\nnot ok 3 - planned # TODO later\n1..3\n")
        @test length(tap["cases"])==3 && tap["framework_summary"]["plan_matches_observed_top_level_cases"]
        @test tap["observed_case_counts"]["failed"]==1 && tap["observed_case_counts"]["expected_failure"]==1
        malformed=parse("tap","ok 1 - first\nok 1 - duplicate\n1..2\nBail out! unavailable\n")
        @test malformed["invalid_records"]==1 && !malformed["framework_summary"]["plan_matches_observed_top_level_cases"]
        @test haskey(malformed["framework_summary"],"bailout")
        pytest=parse("pytest","test_calc.py::test_add FAILED [100%]\nFAILED test_calc.py::test_add - assertion\n1 failed, 2 passed in 0.1s\n")
        @test length(pytest["cases"])==1 && pytest["framework_summary"]["passed"]==2
        events=[Dict("Action"=>"output","Package"=>"calc","Output"=>"    calc_test.go:5: addition failed\n"),
            Dict("Action"=>"fail","Package"=>"calc","Test"=>"TestAdd","Elapsed"=>0.002),Dict("Action"=>"fail","Package"=>"calc")]
        go=parse("go_json",join(canonical.(events),'\n'))
        @test go["observed_case_counts"]["failed"]==1 && go["framework_summary"]["packages_failed"]==1
        @test go["frames"][1]["path"]=="calc_test.go" && go["cases"][1]["duration_seconds"]==0.002
        @test parse("go_json","{malformed}\n")["invalid_records"]==1
        ctest=parse("ctest","1/2 Test #1: addition ........... Passed 0.01 sec\n2/2 Test #2: boundary ........... ***Failed 0.02 sec\n50% tests passed, 1 tests failed out of 2\n")
        @test ctest["observed_case_counts"]["passed"]==1 && ctest["observed_case_counts"]["failed"]==1
        @test ctest["framework_summary"]["tests"]==2
        references=parse("raw","at calculate (file://"*joinpath(root,"src","calc.js")*":12:3)\n../outside.py:4:2: failure\n.env:3:4: secret\nhttps://example.invalid/file.js:2:4: remote\n")
        @test length(references["frames"])==1 && references["frames"][1]["path"]==joinpath("src","calc.js")
        @test !references["frames"][1]["file_existence_checked"]
        large=parse("tap",join(["ok "*string(i)*" - case "*string(i) for i in 1:1100],'\n'))
        @test length(large["cases"])==1024 && large["cases_truncated"]
        @test parse("unittest","Ran 0 tests in 0.000s\nOK\n")["framework_summary"]["tests"]==0
        @test_throws ShenScopeError parse("invented","x")
    end
end

@testset "Testing schemas and plan mode retain discovery and reject execution" begin
    mktempdir() do root
        ctx=project_testing_context(root);tool=TestingTool()
        @test_throws ShenScopeError execute(tool,Dict("action"=>"discover","argv"=>["python3"]),ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"custom","argv"=>["python3"],"timeout"=>true),ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"custom","argv"=>["python3\0"]),ctx)
        with_agent_execution_mode("plan") do
            tools=ShenScope.plan_mode_toolset(AbstractTool[tool]);@test length(tools)==1
            actions=tool_schema(only(tools))["properties"]["action"]["enum"]
            @test "discover" in actions && !("custom" in actions) && !("run" in actions)
            @test execute_call(tool,ToolCall("testing",Dict("action"=>"discover")),ctx).ok
            denied=execute_call(tool,ToolCall("testing",Dict("action"=>"custom","argv"=>["python3","-c","print(1)"])),ctx)
            @test !denied.ok && occursin("plan mode",denied.error)
        end
        close_operations!(tool.operations);cleanup_project_tests!(tool.manager)
    end
end
