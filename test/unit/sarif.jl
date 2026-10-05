function sarif_result(uri; region=Dict("startLine"=>1,"startColumn"=>2,"endColumn"=>5), message=Dict("text"=>"Observed issue"))
    Dict{String,Any}("ruleId"=>"R1", "message"=>message, "level"=>"error",
        "locations"=>[Dict("physicalLocation"=>Dict{String,Any}("artifactLocation"=>Dict{String,Any}("uri"=>uri),"region"=>region))])
end

function sarif_document(results; column_kind="utf16CodeUnits", rules=Any[Dict("id"=>"R1")])
    Dict{String,Any}("version"=>"2.1.0", "runs"=>[Dict{String,Any}("tool"=>Dict("driver"=>Dict("name"=>"fixture-checker","version"=>"1.0","rules"=>rules)),
        "columnKind"=>column_kind,"results"=>results)])
end

function import_sarif_fixture(manager,ctx,document,source; report_path="report.sarif")
    text=ShenScope.canonical(document);write(joinpath(ctx.root,report_path),text)
    import_sarif_report!(manager,ctx;path=report_path,expected_report_sha256=digest(text),
        source_versions=[Dict("path"=>source.path,"expected_sha256"=>source.sha256)])
end

@testset "SARIF import projects Unicode ranges, resolves messages and never runs fixes" begin
    mktempdir() do root
        mkpath(joinpath(root,"src"));write(joinpath(root,"src","a space.py"),"a😀中b\r\nnext\u2028value\n")
        ctx=model_context(root)
        for category in (:process,:network,:dynamic,:persistence);ctx.permissions.rules[category]=Deny;end
        source=read_workspace_snapshot(ctx,"src/a space.py";unicode_line_separators=false)
        manager=ProjectValidationManager()
        rule=Dict("id"=>"R1","defaultConfiguration"=>Dict("level"=>"warning"),
            "messageStrings"=>Dict("m"=>Dict("text"=>"Unsafe {0}; literal {1}")))
        row=sarif_result("src/a%20space.py";message=Dict("id"=>"m","arguments"=>["😀","{0}"]))
        delete!(row,"ruleId");delete!(row,"level");row["rule"]=Dict("id"=>"R1","index"=>0)
        row["fixes"]=[Dict("description"=>Dict("text"=>"untrusted fix"))]
        report=import_sarif_fixture(manager,ctx,sarif_document([row];rules=[rule]),source)
        @test report["outcome"]=="report_imported" && !report["commands_executed"]
        @test !report["automatic_fix_execution"] && report["historical_report_source_binding_is_caller_assertion"]
        projection=project_problem_editor_snapshot(manager.problems,report["problem_snapshot_id"],ctx)
        marker=only(only(projection["files"])["markers"])
        @test marker["message"]=="Unsafe 😀; literal {0}" && marker["severity"]=="warning"
        @test marker["range"]==Dict("start"=>Dict("line"=>0,"character"=>1),"end"=>Dict("line"=>0,"character"=>4))
        @test read(source.absolute,String)==source.source.source
        @test inspect_validation_sources(manager,report["validation_id"],ctx)["all_selected_sources_current"]
        scalar=sarif_result("src/a%20space.py";region=Dict("startLine"=>1,"startColumn"=>2,"endColumn"=>4))
        scalar_report=import_sarif_fixture(manager,ctx,sarif_document([scalar];column_kind="unicodeCodePoints"),source)
        scalar_marker=only(only(project_problem_editor_snapshot(manager.problems,scalar_report["problem_snapshot_id"],ctx)["files"])["markers"])
        @test scalar_marker["range"]==marker["range"]
        write(source.absolute,"changed\n")
        @test project_problem_editor_snapshot(manager.problems,report["problem_snapshot_id"],ctx)["markers"]==0
        @test !inspect_validation_sources(manager,report["validation_id"],ctx)["all_selected_sources_current"]
        @test_throws ShenScopeError import_sarif_fixture(manager,ctx,sarif_document([row];rules=[rule]),source)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError read_validation_report(manager,report["validation_id"],ctx)
    end
end

@testset "SARIF inactive and unlocated reports retain honest coverage" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"a.py"),"a😀中b\n")
        source=read_workspace_snapshot(ctx,"a.py";unicode_line_separators=false)
        unlocated=sarif_result("a.py";region=Dict())
        whole_line=sarif_result("a.py";region=Dict("startLine"=>1))
        absent=merge(sarif_result("a.py"),Dict("baselineState"=>"absent"))
        suppressed=merge(sarif_result("a.py"),Dict("suppressions"=>[Dict("kind"=>"external","status"=>"accepted")]))
        passed=merge(sarif_result("a.py"),Dict("kind"=>"pass"))
        report=import_sarif_fixture(ProjectValidationManager(),ctx,sarif_document([unlocated,whole_line,absent,suppressed,passed]),source)
        coverage=report["coverage"];run=only(coverage["runs"])
        @test coverage["reported_results"]==5 && coverage["retained_diagnostics"]==2
        @test run["omissions"]["baseline_absent_results"]==1
        @test run["omissions"]["suppressed_results"]==1 && run["omissions"]["non_problem_results"]==1
        @test !coverage["complete_project_coverage"] && !coverage["all_sarif_features_supported"]
        files,_=parse_sarif_problems(sarif_document([unlocated,whole_line]),Dict(source.path=>source),ctx)
        @test first(only(files).items).location===nothing
        @test last(only(files).items).metadata["location_precision"]=="derived_reported_lines"
    end
end

@testset "SARIF paths, malformed positions, indexed identities and capacities are bounded" begin
    mktempdir() do root
        ctx=model_context(root);mkpath(joinpath(root,"src"));write(joinpath(root,"src","a.py"),"a😀中b\n")
        source=read_workspace_snapshot(ctx,"src/a.py";unicode_line_separators=false);sources=Dict(source.path=>source)
        for uri in ("https://example.com/a.py","file:///tmp/outside.py","../escape.py","src/a.py?query","src%5Ca.py")
            files,coverage=parse_sarif_problems(sarif_document([sarif_result(uri)]),sources,ctx)
            @test isempty(only(files).items)
            @test only(coverage["runs"])["omissions"]["invalid_or_unavailable_locations"]==1
        end
        for region in (Dict("startLine"=>1,"startColumn"=>3,"endColumn"=>5),
                Dict("startLine"=>1,"startColumn"=>5,"endColumn"=>2),Dict("startLine"=>100),Dict("startLine"=>true))
            files,coverage=parse_sarif_problems(sarif_document([sarif_result("src/a.py";region)]),sources,ctx)
            @test isempty(only(files).items)
            @test only(coverage["runs"])["omissions"]["invalid_or_unavailable_locations"]==1
        end
        document=sarif_document([sarif_result("src/a.py")]);run=only(document["runs"])
        location=only(only(run["results"])["locations"])["physicalLocation"]["artifactLocation"]
        empty!(location);location["index"]=0
        run["artifacts"]=[Dict("location"=>Dict("uri"=>"a.py","uriBaseId"=>"SRC"))]
        run["originalUriBaseIds"]=Dict("SRC"=>Dict("uri"=>"src/"))
        files,coverage=parse_sarif_problems(document,sources,ctx)
        @test length(only(files).items)==1 && coverage["retained_diagnostics"]==1
        run["originalUriBaseIds"]["SRC"]=Dict("uri"=>"","uriBaseId"=>"SRC")
        files,coverage=parse_sarif_problems(document,sources,ctx)
        @test isempty(only(files).items) && only(coverage["runs"])["omissions"]["invalid_or_unavailable_locations"]==1
        delete!(run,"originalUriBaseIds")
        @test isempty(only(first(parse_sarif_problems(document,sources,ctx))).items)
        mismatch=merge(sarif_result("src/a.py"),Dict("ruleIndex"=>0,"ruleId"=>"other"))
        _,coverage=parse_sarif_problems(sarif_document([mismatch]),sources,ctx)
        @test only(coverage["runs"])["invalid_results"]==1
        @test_throws ShenScopeError parse_sarif_problems(sarif_document([mismatch];rules=[Dict("id"=>"R1"),Dict("id"=>"R1")]),sources,ctx)
        @test_throws ShenScopeError parse_sarif_problems(sarif_document([sarif_result("src/a.py"),sarif_result("src/a.py")]),sources,ctx;limits=SarifLimits(;maximum_results=1))
        @test_throws ShenScopeError parse_sarif_problems(document,sources,ctx;maximum_diagnostics=true)
        files,coverage=parse_sarif_problems(sarif_document([sarif_result("src/a.py"),sarif_result("src/a.py")]),sources,ctx;maximum_diagnostics=1)
        @test length(only(files).items)==1 && only(coverage["runs"])["omissions"]["diagnostic_capacity"]==1
    end
end

@testset "SARIF comparison preserves source/configuration changes without reexecution" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"a.py"),"a😀中b\n")
        source=read_workspace_snapshot(ctx,"a.py";unicode_line_separators=false);manager=ProjectValidationManager()
        before=import_sarif_fixture(manager,ctx,sarif_document([sarif_result("a.py")]),source)
        after=import_sarif_fixture(manager,ctx,sarif_document(Any[]),source)
        comparison=compare_project_validation_reports(manager,before["validation_id"],after["validation_id"],ctx)
        @test comparison["diagnostic_changes"]["removed_total"]==1
        @test comparison["same_selected_source_versions"] && comparison["same_output_configuration"]
        @test comparison["same_command_candidate"]===nothing && !comparison["commands_reexecuted"]
        @test !comparison["missing_report_rows_prove_repair"]
        foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
        @test_throws ShenScopeError compare_project_validation_reports(manager,before["validation_id"],after["validation_id"],foreign)
        raw="{\"version\":\"2.1.0\",\"version\":\"2.1.0\",\"runs\":[]}"
        write(joinpath(root,"duplicate.sarif"),raw)
        @test_throws ShenScopeError import_sarif_report!(manager,ctx;path="duplicate.sarif",expected_report_sha256=digest(raw),
            source_versions=[Dict("path"=>source.path,"expected_sha256"=>source.sha256)])
    end
end
