@testset "Testing RPC approvals, owning jobs, no replay and independent result reads" begin
    mktempdir() do root
        project_testing_fixture(root,"python")
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            hello=dispatch_rpc(server,"initialize",Dict())
            @test hello["capabilities"]["project_testing"]["argument_vector_any_language"]
            @test !hello["capabilities"]["project_testing"]["automatic_replay"]
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            other=dispatch_rpc(server,"sessions/create",Dict())["id"]
            @test_throws RPCFault dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"discover"))
            started=dispatch_rpc(server,"testing/start",Dict("session_id"=>owner,"action"=>"discover"))
            catalog_job=project_testing_job(server,owner,started["job_id"])
            @test catalog_job["status"]=="complete" && length(catalog_job["result"]["candidates"])==1
            @test_throws ShenScopeError dispatch_rpc(server,"testing/job",Dict("session_id"=>other,"job_id"=>started["job_id"]))
            catalog=catalog_job["result"];candidate=only(catalog["candidates"])
            @test dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"catalog","catalog_id"=>catalog["catalog_id"]))==catalog
            arguments=Dict("session_id"=>owner,"action"=>"run","catalog_id"=>catalog["catalog_id"],"candidate_id"=>candidate["id"])
            pending=dispatch_rpc(server,"testing/start",arguments)
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.025)==:ok
            @test isempty(ShenScope.server_testing_tool(server).manager.reports)
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"Do not overlap"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/mode",Dict("session_id"=>owner,"action"=>"set","mode"=>"plan","expected_revision"=>0))
            request_id=only(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>other,"request_id"=>request_id,"decision"=>"once"))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request_id,"decision"=>"once"))
            execution=project_testing_job(server,owner,pending["job_id"])
            @test execution["status"]=="complete" && execution["result"]["outcome"]=="command_failed"
            report=execution["result"]
            @test dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"report","run_id"=>report["run_id"]))==report
            @test_throws ShenScopeError dispatch_rpc(server,"testing/query",Dict("session_id"=>other,"action"=>"report","run_id"=>report["run_id"]))
            context=server.contexts[owner];context.permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"testing/job",Dict("session_id"=>owner,"job_id"=>pending["job_id"]))
            @test hidden["result"]===nothing && hidden["result_hidden_by_permission"]
            event=AgentEvent(1,:testing_job_completed,owner,"fixture",ShenScope.utcstamp(),Dict("result"=>report,"status"=>"complete"))
            delivery=ShenScope.testing_event_payload(server,event,event.payload)
            @test delivery["result"]===nothing && delivery["result_hidden_by_permission"] && event.payload["result"]==report
            tool_event=AgentEvent(2,:tool_completed,owner,"fixture",ShenScope.utcstamp(),Dict("name"=>"testing","value"=>report,"ok"=>false))
            @test ShenScope.testing_event_payload(server,tool_event,tool_event.payload)["value"]===nothing
            @test_throws ShenScopeError dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"reports"))
            context.permissions.rules[:read]=Ask
            @test_throws ShenScopeError dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"reports"))
            @test isempty(server.approvals)
            context.permissions.rules[:read]=Allow
            frame=first(report["parsed"]["frames"])
            source=dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"source","run_id"=>report["run_id"],"frame_id"=>frame["id"]))
            @test source["path"]==frame["path"] && !source["execution_source_snapshot_verified"]
            waiting=dispatch_rpc(server,"testing/start",arguments)
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.025)==:ok
            dispatch_rpc(server,"testing/cancel_job",Dict("session_id"=>owner,"job_id"=>waiting["job_id"]))
            cancelled=project_testing_job(server,owner,waiting["job_id"])
            @test cancelled["status"]=="cancelled" && cancelled["result"]===nothing
            @test isempty(server.approvals)
            @test length(ShenScope.server_testing_tool(server).manager.reports)==1
            @test_throws ShenScopeError dispatch_rpc(server,"testing/start",Dict("session_id"=>owner,"action"=>"discover","owner"=>other))
        finally
            stop_server!(server)
        end
    end
end

@testset "CLI candidate discovery, real failing command and terminal test controls" begin
    mktempdir() do root
        project_testing_fixture(root,"python");ctx=project_testing_context(root);tool=TestingTool()
        command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(dirname(@__DIR__))) -e 'using ShenScope; exit(ShenScope.main(ARGS))'`
        common=["--root",root,"--state-dir",ctx.state_dir,"--config",joinpath(root,"config.toml")]
        catalog=parsejson(read(`$command tests discover $common`,String))
        @test length(catalog["candidates"])==1
        buffer=IOBuffer()
        process=run(pipeline(ignorestatus(`$command tests run $(only(catalog["candidates"])["id"]) $common --allow-process`);stdout=buffer))
        receipt=parsejson(String(take!(buffer)))
        @test process.exitcode==1 && receipt["outcome"]=="command_failed"
        raw=read(`$command tests custom $common --allow-process --argv '["python3","-c","print(42)"]'`,String)
        @test parsejson(raw)["exit_code"]==0 && isempty(parsejson(raw)["parsed"]["cases"])
        state=ShenScope.TerminalState();tools=AbstractTool[tool]
        ShenScope.terminal_testing_command!(state,"/tests",ctx,tools)
        @test any(line->occursin("none executed",line),state.lines)
        ShenScope.terminal_testing_command!(state,"/test "*only(catalog["candidates"])["id"],ctx,tools)
        @test any(line->occursin("command_failed",line),state.lines)
        @test any(line->occursin("test_calc.py",line),state.lines)
        @test_throws ShenScopeError ShenScope.terminal_testing_command!(state,"/test",ctx,tools)
        close_operations!(tool.operations);cleanup_project_tests!(tool.manager)
    end
end
