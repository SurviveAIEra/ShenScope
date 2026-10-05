@testset "A real agent tool call compiles, archives and reads its own durable compiler evidence" begin
    mktempdir() do root
        ctx=compiler_archive_context(root);tool=DiagnosticsTool();session=new_session(ctx)
        arguments=Dict("action"=>"compile_archive","target"=>"digest_string","expected_revision"=>0,
            "title"=>"Agent compiler evidence 中文","timeout"=>120)
        provider=MockProvider([response(;calls=[ToolCall("diagnostics",arguments)]),
            response(;calls=[ToolCall("diagnostics",Dict("action"=>"archive_list"))]),response("Inference archived.")])
        @test run_agent!(provider,"Compile and save evidence, then verify the archive",ctx;session,tools=[tool])=="Inference archived."
        catalog=compiler_archive_list(compiler_archive_store(ctx),ctx)
        @test catalog["total"]==1 && catalog["items"][1]["title"]==arguments["title"]
        loaded=compiler_archive_get(compiler_archive_store(ctx),catalog["items"][1]["report_sha256"],ctx)
        @test loaded["report"]["target"]=="digest_string" && loaded["execution"]["separate_process"]
        @test session.status==:complete && length(provider.requests)==3
        tool_results=[parsejson(message.text) for message in session.messages if message.role==:tool]
        @test length(tool_results)==2 && all(value->value["ok"],tool_results)
        @test tool_results[2]["value"]["total"]==1
        emitted=AgentEvent[]
        guarded=compiler_archive_context(root;sink=event->push!(emitted,event))
        @test_throws ShenScopeError execute(tool,merge(arguments,Dict("expected_revision"=>0)),guarded)
        @test isempty(filter(event->event.kind==:permission_request,emitted))
        guarded.permissions.rules[:persistence]=Deny
        @test_throws ShenScopeError execute(tool,merge(arguments,Dict("expected_revision"=>1)),guarded)
        @test isempty(filter(event->event.kind in (:compiler_diagnostic,:backend_started),emitted))
        @test_throws ShenScopeError execute(tool,merge(arguments,Dict("mode"=>"lowered","expected_revision"=>1)),ctx)
        @test_throws ShenScopeError execute(tool,merge(arguments,Dict("job_id"=>"unexpected")),ctx)
    end
end
