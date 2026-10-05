@testset "Editor testing projection distinguishes commands from observed cases" begin
    mktempdir() do root
        project_testing_fixture(root,"python");ctx=project_testing_context(root;session_id="editor-tests");manager=ProjectTestManager()
        catalog=discover_project_tests!(manager,ctx);candidate=only(catalog["candidates"])
        collection=project_test_editor_catalog(manager,catalog["catalog_id"],ctx)
        @test !collection["individual_test_discovery"] && !collection["automatic_execution"]
        @test only(collection["commands"])["kind"]=="command" && only(collection["commands"])["id"]==candidate["id"]
        @test collection["session_id"]==ctx.session_id && collection["root_sha256"]==digest(ctx.root)
        report=run_project_tests!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_id=candidate["id"])
        projection=project_test_editor_result(manager,report["run_id"],ctx)
        @test projection["state"]=="failed" && only(projection["cases"])["state"]=="failed"
        @test !only(projection["cases"])["runnable_individually"]
        @test !projection["complete_project_coverage"] && !projection["case_results_independently_verified"] && !projection["case_source_associations_verified"]
        @test projection["report_sha256"]==report["sha256"] && !isempty(projection["source_references"])
        @test project_test_editor_result(manager,report["run_id"],ctx;case_limit=0)["projection_truncated"]
        @test_throws ShenScopeError project_test_editor_result(manager,report["run_id"],ctx;case_limit=true)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError project_test_editor_catalog(manager,catalog["catalog_id"],ctx)
        @test_throws ShenScopeError project_test_editor_result(manager,report["run_id"],ctx)
    end
end

@testset "Selected project commands preserve order, bounded receipts and stop choices" begin
    mktempdir() do root
        mkpath(joinpath(root,"python"));mkpath(joinpath(root,"javascript"))
        project_testing_fixture(joinpath(root,"python"),"python");project_testing_fixture(joinpath(root,"javascript"),"javascript")
        ctx=project_testing_context(root;session_id="selected-tests");manager=ProjectTestManager()
        catalog=discover_project_tests!(manager,ctx);python=only(filter(c->c["framework"]=="unittest",catalog["candidates"]))
        javascript=only(filter(c->c["language"]=="javascript/typescript",catalog["candidates"]))
        write(joinpath(root,"javascript","calc.mjs"),"export function add(a,b) { return a+b; }\n")
        ids=[python["id"],javascript["id"]]
        stopped=run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=ids,stop_on_failure=true)
        @test stopped["outcome"]=="run_set_failed" && length(stopped["commands"])==1
        @test stopped["not_started_candidate_ids"]==[javascript["id"]]
        continued=run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=ids)
        @test getindex.(continued["commands"],"candidate_id")==ids && isempty(continued["not_started_candidate_ids"])
        @test continued["commands"][1]["result"]["state"]=="failed" && continued["commands"][2]["result"]["state"]=="passed"
        @test all(row->row["execution_receipt_available"],continued["commands"])
        @test !continued["parallel_execution"] && !continued["automatic_replay"] && !continued["complete_project_coverage"]
        body=Dict(key=>value for (key,value) in continued if key!="sha256")
        @test digest(canonical(body))==continued["sha256"]
        @test all(row->ncodeunits(canonical(read_project_test_report(manager,row["result"]["run_id"],ctx)))<=512*1024,continued["commands"])
        count_before=length(manager.reports)
        @test_throws ShenScopeError run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=vcat(ids,[digest("absent")]))
        @test_throws ShenScopeError run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=[python["id"],python["id"]])
        @test_throws ShenScopeError run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=ids,output_limit=1024^2)
        @test length(manager.reports)==count_before
        write(joinpath(root,"javascript","package.json"),"{\"scripts\":{\"test\":\"node -e \\\"console.log(42)\\\"\"}}")
        @test_throws ShenScopeError run_project_test_set!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_ids=ids)
        @test length(manager.reports)==count_before
    end
end

@testset "Process session grants survive rediscovery but bind the absolute command directory" begin
    mktempdir() do root
        project_testing_fixture(root,"python");ctx=project_testing_context(root;session_id="stable-test-grant");manager=ProjectTestManager()
        ctx.permissions.rules[:process]=Ask;approvals=Ref(0);ctx.approve=request->begin;approvals[]+=1;:session;end
        first_catalog=discover_project_tests!(manager,ctx)
        run_project_tests!(manager,ctx;catalog_id=first_catalog["catalog_id"],candidate_id=only(first_catalog["candidates"])["id"])
        second_catalog=discover_project_tests!(manager,ctx)
        run_project_tests!(manager,ctx;catalog_id=second_catalog["catalog_id"],candidate_id=only(second_catalog["candidates"])["id"])
        @test approvals[]==1 && first_catalog["catalog_id"]!=second_catalog["catalog_id"]
        mktempdir() do other
            project_testing_fixture(other,"python")
            foreign=RuntimeContext(other;session_id=ctx.session_id,state_dir=joinpath(other,"state"),permissions=ctx.permissions,approve=ctx.approve)
            third=discover_project_tests!(manager,foreign)
            run_project_tests!(manager,foreign;catalog_id=third["catalog_id"],candidate_id=only(third["candidates"])["id"])
            @test approvals[]==2
        end
    end
end
