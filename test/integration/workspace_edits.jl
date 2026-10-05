@testset "Applied Python and JavaScript changes bind actual verification receipts" begin
    for language in ("python","javascript")
        mktempdir() do root
            project_testing_fixture(root,language);ctx=project_testing_context(root);testing=ProjectTestManager();edits=WorkspaceEditManager()
            catalog=discover_project_tests!(testing,ctx);candidate=only(catalog["candidates"])
            failed=run_project_tests!(testing,ctx;catalog_id=catalog["catalog_id"],candidate_id=candidate["id"])
            @test failed["outcome"]!="command_succeeded"
            path=language=="python" ? "calc.py" : "calc.mjs"
            file=workspace_replacement(ctx,path,"a-b","a+b")
            # Fixtures differ only in spacing. Use the actual declared text.
            proposal=prepare_workspace_edits!(edits,ctx,[file])
            @test apply_workspace_edits!(edits,proposal["plan_id"],ctx;expected_plan_sha256=proposal["plan_sha256"])["outcome"]=="applied"
            verified=verify_workspace_edits!(edits,testing,proposal["plan_id"],ctx;
                expected_plan_sha256=proposal["plan_sha256"],catalog_id=catalog["catalog_id"],candidate_ids=[candidate["id"]])
            @test verified["outcome"]=="command_succeeded" && verified["edited_source_versions_unchanged_during_commands"]
            @test !verified["complete_project_coverage"] && !verified["all_project_inputs_snapshotted"]
            @test only(verified["commands"])["execution_receipt_available"]
            @test read_workspace_edit_plan(edits,proposal["plan_id"],ctx)["verification"]["sha256"]==verified["sha256"]
        end
    end
end
