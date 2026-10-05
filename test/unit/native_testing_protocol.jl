@testset "Correlated testing jobs recover existing work and reject request replay" begin
    mktempdir() do root
        project_testing_fixture(root,"python")
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict())
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"];foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            discovery=dispatch_rpc(server,"testing/start",Dict("session_id"=>owner,"action"=>"discover"))
            catalog=project_testing_job(server,owner,discovery["job_id"])["result"]
            projected=dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"editor_catalog","catalog_id"=>catalog["catalog_id"]))
            @test only(projected["commands"])["kind"]=="command"
            nonce="native-test-request-one"
            arguments=Dict("session_id"=>owner,"action"=>"run_set","catalog_id"=>catalog["catalog_id"],
                "candidate_ids"=>[only(catalog["candidates"])["id"]],"client_request_id"=>nonce)
            launched=dispatch_rpc(server,"testing/start",arguments)
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.025)==:ok
            found=dispatch_rpc(server,"testing/find_job",Dict("session_id"=>owner,"client_request_id"=>nonce))
            @test found["found"] && found["job"]["job_id"]==launched["job_id"] && !found["automatic_replay"]
            @test found["job"]["trace_id"]==launched["trace_id"]
            @test !dispatch_rpc(server,"testing/find_job",Dict("session_id"=>foreign,"client_request_id"=>nonce))["found"]
            request=only(keys(server.approvals))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>"once"))
            complete=project_testing_job(server,owner,launched["job_id"])
            @test complete["status"]=="complete" && complete["result"]["outcome"]=="run_set_failed"
            row=only(complete["result"]["commands"])
            @test dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"editor_result","run_id"=>row["result"]["run_id"]))==row["result"]
            @test_throws ShenScopeError dispatch_rpc(server,"testing/start",arguments)
            @test length(ShenScope.server_testing_tool(server).manager.reports)==1
            loaded=dispatch_rpc(server,"testing/find_job",Dict("session_id"=>owner,"client_request_id"=>nonce))
            @test loaded["job"]["result"]==complete["result"]
            server.contexts[owner].permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"testing/find_job",Dict("session_id"=>owner,"client_request_id"=>nonce))
            @test hidden["job"]["result"]===nothing && hidden["job"]["result_hidden_by_permission"]
            event=AgentEvent(1,:testing_run_set_progress,owner,"fixture",ShenScope.utcstamp(),Dict("command"=>row))
            @test ShenScope.testing_event_payload(server,event,event.payload)==Dict("evidence_hidden_by_permission"=>true)
            @test_throws ShenScopeError dispatch_rpc(server,"testing/find_job",Dict("session_id"=>owner,"client_request_id"=>nonce,"owner"=>foreign))
            @test_throws ShenScopeError dispatch_rpc(server,"testing/find_job",Dict("session_id"=>owner))
        finally;stop_server!(server);end
    end
end
