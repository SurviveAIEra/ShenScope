@testset "Real Python, C, C++ and Go checks produce source-bound Problems and repair receipts" begin
    cases=[("python","sample.py","def broken(:\n    pass\n","value = 1\n",["python3","-m","py_compile","sample.py"]),
        ("gcc","sample.c","int main(void) { return unknown; }\n","int main(void) { return 0; }\n",["gcc","-fsyntax-only","-fdiagnostics-color=never","sample.c"]),
        ("gcc","sample.cpp","int main() { return unknown; }\n","int main() { return 0; }\n",["g++","-fsyntax-only","-fdiagnostics-color=never","sample.cpp"]),
        ("go","sample.go","package example\nfunc Value() int { return missing }\n","package example\nfunc Value() int { return 1 }\n",[get(ENV,"SHENSCOPE_TEST_GO","/workspace/toolchains/go-1.27.1/bin/go"),"tool","compile","sample.go"])]
    for (family,path,broken,fixed,argv) in cases
        mktempdir() do root
            ctx=model_context(root);manager=ProjectValidationManager()
            write(joinpath(root,path),broken)
            first=run_project_validation!(manager,ctx;argv,paths=[path],family,timeout=30)
            @test first["outcome"] != "command_succeeded" && first["selected_source_versions_unchanged"]
            projection=project_problem_editor_snapshot(manager.problems,first["problem_snapshot_id"],ctx)
            @test projection["markers"]>=1 && only(projection["files"])["source_sha256"]==digest(broken)
            @test read_validation_report(manager,first["validation_id"],ctx)["sha256"]==first["sha256"]
            write(joinpath(root,path),fixed)
            @test project_problem_editor_snapshot(manager.problems,first["problem_snapshot_id"],ctx)["markers"]==0
            second=run_project_validation!(manager,ctx;argv,paths=[path],family,timeout=30)
            @test second["outcome"]=="command_succeeded" && second["exit_code"]==0
            @test project_problem_editor_snapshot(manager.problems,second["problem_snapshot_id"],ctx)["markers"]==0
            @test !second["complete_project_coverage"] && !second["all_project_inputs_snapshotted"]
            foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
            @test_throws ShenScopeError read_validation_report(manager,first["validation_id"],foreign)
            @test length(list_validation_reports(manager,ctx)["reports"])==2
            isfile(joinpath(root,"sample.o")) && rm(joinpath(root,"sample.o"))
            ctx.permissions.rules[:read]=Deny
            @test_throws ShenScopeError read_validation_report(manager,second["validation_id"],ctx)
        end
    end
end

@testset "Validation parser refuses invented columns, unavailable sources and output overflows" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"sample.c"),"中😀value\n")
        source=read_workspace_snapshot(ctx,"sample.c";unicode_line_separators=false)
        limits=ValidationLimits(;maximum_lines=2,maximum_line_bytes=128,maximum_diagnostics=1)
        frames,summary=ShenScope.parse_validation_output("sample.c:1:9: error: first\nsample.c:1:8: warning: second\nextra\n","gcc","stderr",limits)
        @test length(frames)==1 && summary["rows_omitted"]>=2
        files,metadata=ShenScope.validation_problem_files(frames,Dict("sample.c"=>source),ctx,root,"gcc","unknown",limits)
        @test only(only(files).items).metadata["location_precision"]=="reported_line"
        @test only(only(files).items).location.start_column==1
        other=ShenScope.ValidationDiagnosticFrame("../outside.c",1,1,"error","unowned",nothing,"stderr",1)
        _,summary=ShenScope.validation_problem_files([other],Dict("sample.c"=>source),ctx,root,"gcc","utf8_byte",limits)
        @test summary["references_outside_selected_sources"]==1
        malformed=ShenScope.ValidationDiagnosticFrame("sample.c",100,1,"error","bad range",nothing,"stderr",1)
        _,summary=ShenScope.validation_problem_files([malformed],Dict("sample.c"=>source),ctx,root,"gcc","utf8_byte",limits)
        @test summary["invalid_source_ranges"]==1
    end
end
