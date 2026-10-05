@testset "Plan RPC owns sessions, mode revisions and current Read gates" begin
    mktempdir() do root
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\npersistence='allow'\nnetwork='deny'\n")
        reply=request->begin sleep(0.1);response("Read-only reply") end
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer(),
            provider_factory=server->MockProvider(Any[reply]))
        try
            hello=dispatch_rpc(server,"initialize",Dict())
            @test hello["capabilities"]["conversation_plans"]
            created=dispatch_rpc(server,"sessions/create",Dict("title"=>"Plan owner"));id=created["id"]
            @test created["agent_mode"]["mode"]=="act"
            setting=dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id,"action"=>"set","mode"=>"plan","expected_revision"=>0))
            @test setting["committed"] && setting["revision"]==1
            @test dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id))["mode"]=="plan"
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id,"action"=>"set","mode"=>"act","expected_revision"=>0))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id,"mode"=>"act"))
            @test_throws ShenScopeError dispatch_rpc(server,"plans/query",Dict("session_id"=>id,"owner"=>"foreign"))
            session=load_session(server.state_dir,id);ctx=ShenScope.plan_controller_context(server,id)
            ShenScope.add_message!(session,Message(:user,"Plan request"));save_plan_fixture(session,ctx)
            @test dispatch_rpc(server,"plans/query",Dict("session_id"=>id))["revision"]==1
            @test length(dispatch_rpc(server,"plans/history",Dict("session_id"=>id))["items"])==1
            @test !haskey(dispatch_rpc(server,"sessions/get",Dict("session_id"=>id))["metadata"],"work_plan")
            @test dispatch_rpc(server,"sessions/export",Dict("session_id"=>id))["metadata"]["work_plan"]["revision"]==1
            foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Separate conversation"))["id"]
            @test dispatch_rpc(server,"plans/query",Dict("session_id"=>foreign))["plan"]===nothing
            @test dispatch_rpc(server,"sessions/mode",Dict("session_id"=>foreign))["mode"]=="act"
            ctx.permissions.rules[:read]=Deny
            @test_throws ShenScopeError dispatch_rpc(server,"plans/query",Dict("session_id"=>id))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/export",Dict("session_id"=>id))
            ctx.permissions.rules[:read]=Ask
            @test_throws ShenScopeError dispatch_rpc(server,"plans/history",Dict("session_id"=>id))
            @test isempty(server.approvals)
            ctx.permissions.rules[:read]=Allow
            dispatch_rpc(server,"agent/start",Dict("session_id"=>id,"prompt"=>"Read-only reply"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id,"action"=>"set","mode"=>"act","expected_revision"=>1))
            @test timedwait(()->!haskey(server.runs,id),60;pollint=0.01)==:ok
            @test dispatch_rpc(server,"sessions/mode",Dict("session_id"=>id))["mode"]=="plan"
        finally
            stop_server!(server)
        end
    end
end
