@testset "Reviewed Python, JavaScript and C edits bind real compiler check receipts" begin
    cases=[("sample.py","def broken(:\n    pass\n","value = 1\n","python",["python3","-m","py_compile","sample.py"]),
        ("sample.mjs","export function broken( {\n","export const value = 1;\n","generic",["node","--check","sample.mjs"]),
        ("sample.c","int main(void) { return missing; }\n","int main(void) { return 0; }\n","gcc",["gcc","-fsyntax-only","sample.c"])]
    for (path,broken,fixed,family,argv) in cases
        mktempdir() do root
            write(joinpath(root,path),broken);ctx=model_context(root)
            validation=ProjectValidationManager();edits=WorkspaceEditManager()
            before=run_project_validation!(validation,ctx;argv,paths=[path],family)
            @test before["outcome"]!="command_succeeded"
            proposal=prepare_workspace_edits!(edits,ctx,[workspace_replacement(ctx,path,broken,fixed)])
            @test_throws ShenScopeError verify_workspace_check!(edits,validation,proposal["plan_id"],ctx;
                expected_plan_sha256=proposal["plan_sha256"],argv,family)
            applied=apply_workspace_edits!(edits,proposal["plan_id"],ctx;expected_plan_sha256=proposal["plan_sha256"])
            verified=verify_workspace_check!(edits,validation,proposal["plan_id"],ctx;
                expected_plan_sha256=proposal["plan_sha256"],argv,family)
            @test verified["outcome"]=="command_succeeded" && verified["verification_kind"]=="project_check"
            @test verified["application_receipt_sha256"]==applied["sha256"]
            execution=read_project_test_report(validation.testing,verified["execution_run_id"],ctx)
            @test execution["sha256"]==verified["execution_receipt_sha256"]
            after=read_validation_report(validation,verified["validation_id"],ctx)
            comparison=compare_project_validation_reports(validation,before["validation_id"],after["validation_id"],ctx)
            @test comparison["same_command_arguments_and_directory"] && comparison["same_output_configuration"]
            @test !comparison["same_command_candidate"] # Different descriptive labels remain distinct candidates.
            @test comparison["changed_selected_paths"]==[path] && !comparison["same_selected_source_versions"]
            @test comparison["after_source_status"]["all_selected_sources_current"]
            @test read_workspace_edit_plan(edits,proposal["plan_id"],ctx)["verification"]["sha256"]==verified["sha256"]
        end
    end
end

@testset "Source drift makes reviewed check verification unconfirmed and prevents replay" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"sample.py"),"value = 0\n")
        edits=WorkspaceEditManager();validation=ProjectValidationManager()
        proposal=prepare_workspace_edits!(edits,ctx,[workspace_replacement(ctx,"sample.py","0","1")])
        apply_workspace_edits!(edits,proposal["plan_id"],ctx;expected_plan_sha256=proposal["plan_sha256"])
        argv=["python3","-c","from pathlib import Path; Path('sample.py').write_text('external = 2\\n')"]
        result=verify_workspace_check!(edits,validation,proposal["plan_id"],ctx;
            expected_plan_sha256=proposal["plan_sha256"],argv)
        @test result["outcome"]=="verification_unconfirmed" && result["commands_may_have_run"]
        @test !result["automatic_replay"] && read(joinpath(root,"sample.py"),String)=="external = 2\n"
        again=verify_workspace_check!(edits,validation,proposal["plan_id"],ctx;
            expected_plan_sha256=proposal["plan_sha256"],argv=["python3","-c","print('must not execute')"])
        @test again["outcome"]=="verification_unconfirmed" && !again["commands_may_have_run"]
        @test_throws ShenScopeError apply_workspace_edits!(edits,proposal["plan_id"],ctx;expected_plan_sha256=proposal["plan_sha256"])
        @test length(list_validation_reports(validation,ctx)["reports"])==1
    end
end
