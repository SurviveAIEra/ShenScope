@testset "Language configurations survive restart with CAS and independent Persistence permission" begin
    mktempdir() do root
        ctx=model_context(root);ctx.permissions.rules[:persistence]=Allow
        spec=language_server_spec(Dict("name"=>"python","argv"=>["python3","-u","server.py"],"languages"=>["python"]))
        store=language_catalog_store(ctx)
        saved=save_language_configuration!(store,spec,ctx;expected_version=0)
        @test saved["version"]==1 && !saved["command_started"] && !saved["process_permission_granted"]
        @test read_language_configuration(language_catalog_store(ctx),"python",ctx)["configuration_sha256"]==spec.fingerprint
        @test only(list_language_configurations(store,ctx)["configurations"])["server"]=="python"
        @test_throws ShenScopeError save_language_configuration!(store,spec,ctx;expected_version=0)
        @test_throws ShenScopeError read_language_configuration(store,"python",ctx;expected_version=2)
        foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
        @test_throws ShenScopeError list_language_configurations(store,foreign)
        ctx.permissions.rules[:persistence]=Deny
        @test_throws ShenScopeError remove_language_configuration!(store,"python",ctx;expected_version=1)
        @test read_language_configuration(store,"python",ctx)["version"]==1
        ctx.permissions.rules[:persistence]=Allow
        @test remove_language_configuration!(store,"python",ctx;expected_version=1)["version"]==2
        @test isempty(list_language_configurations(store,ctx)["configurations"])
        @test_throws ShenScopeError read_language_configuration(store,"python",ctx)
    end
end

@testset "Unversioned language reports never become current editor markers" begin
    mktempdir() do root
        write(joinpath(root,"a.py"),"value = 1\n");ctx=model_context(root);source=read_workspace_snapshot(ctx,"a.py";unicode_line_separators=false)
        spec=language_server_spec(Dict("name"=>"python","argv"=>["python3"],"languages"=>["python"]))
        client=LanguageClient(spec,ctx);client.state=:ready
        client.documents["a.py"]=ShenScope.LanguageDocument(source,"python",2,1,time(),ProjectProblem[],nothing,false,0,0)
        diagnostic=Dict("range"=>Dict("start"=>Dict("line"=>0,"character"=>0),"end"=>Dict("line"=>0,"character"=>5)),"message"=>"reported issue","severity"=>2)
        params=Dict("uri"=>ShenScope.mcp_file_uri(source.absolute),"diagnostics"=>[diagnostic])
        ShenScope.receive_language_diagnostics!(client,merge(params,Dict("version"=>1)))
        @test !client.documents["a.py"].diagnostic_received
        ShenScope.receive_language_diagnostics!(client,params)
        manager=ProblemManager();unversioned=capture_language_problems!(manager,client,ctx)
        @test project_problem_editor_snapshot(manager,unversioned.id,ctx)["markers"]==0
        @test only(problem_snapshot_read(manager,unversioned.id,ctx;include_stale=true)["files"])["freshness"]=="producer_version_unverified"
        ShenScope.receive_language_diagnostics!(client,merge(params,Dict("version"=>2)))
        verified=capture_language_problems!(manager,client,ctx)
        @test project_problem_editor_snapshot(manager,verified.id,ctx)["markers"]==1
    end
end

@testset "Completion and signature projections preserve snippets and reject split surrogate offsets" begin
    mktempdir() do root
        write(joinpath(root,"a.py"),"add(1, 2)\n");ctx=model_context(root);source=read_workspace_snapshot(ctx,"a.py";unicode_line_separators=false)
        range=Dict("start"=>Dict("line"=>0,"character"=>0),"end"=>Dict("line"=>0,"character"=>3))
        completion=ShenScope.normalize_language_completions([Dict("label"=>"add","insertTextFormat"=>2,"insertText"=>"add(\${1:a})",
            "textEdit"=>Dict("range"=>range,"newText"=>"add(\${1:a})"))],source)
        @test only(completion["items"])["insert_text_format"]=="snippet" && !only(completion["items"])["plain_edit_applicable"]
        @test !completion["automatic_insertion"]
        commands=ShenScope.normalize_language_completions([Dict("label"=>"add","command"=>Dict("command"=>"unsafe"))],source)
        @test only(commands["items"])["requires_command_execution"] && !only(commands["items"])["plain_edit_applicable"]
        signature=ShenScope.normalize_language_signature_help(Dict("signatures"=>[Dict("label"=>"f(😀)","parameters"=>[Dict("label"=>[2,4])])]))
        @test only(only(signature["signatures"])["parameters"])["label"]["text"]=="😀"
        @test_throws ShenScopeError ShenScope.normalize_language_signature_help(Dict("signatures"=>[Dict("label"=>"f(😀)","parameters"=>[Dict("label"=>[2,3])])]))
    end
end
