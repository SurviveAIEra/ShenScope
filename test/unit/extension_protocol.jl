@testset "Extension RPC approvals, results and cancellation belong to a conversation" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\ndynamic='ask'\nprocess='deny'\npersistence='allow'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            ShenScope.dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            id=ShenScope.dispatch_rpc(server,"sessions/create",Dict("title"=>"Extensions"))["id"]
            foreign=ShenScope.dispatch_rpc(server,"sessions/create",Dict("title"=>"Separate"))["id"]
            control=ShenScope.server_extensions_tool(server)
            register_extension!(control.registry,ExtensionLifecycleFixtures.bundle(),ExtensionLifecycleFixtures.context(root))
            job=ShenScope.dispatch_rpc(server,"extensions/start",Dict("session_id"=>id,"action"=>"activate","name"=>"counter_extension"))["job_id"]
            @test timedwait(()->!isempty(server.approvals),60)==:ok
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"extensions/job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"extensions/cancel_job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"agent/start",Dict("session_id"=>id,"prompt"=>"Do work"))
            request=only(keys(server.approvals))
            ShenScope.dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"session"))
            @test timedwait(()->ShenScope.dispatch_rpc(server,"extensions/job",Dict("session_id"=>id,"job_id"=>job))["status"]!="running",60)==:ok
            finished=ShenScope.dispatch_rpc(server,"extensions/job",Dict("session_id"=>id,"job_id"=>job))
            @test finished["status"]=="complete" && finished["result"]["phase"]=="active"
            @test length(ShenScope.dispatch_rpc(server,"extensions/query",Dict("session_id"=>id))["extensions"])==1
            context=server.contexts[id]
            context.permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Ask,:process=>Deny,:persistence=>Allow,:network=>Deny))
            cancel=ShenScope.dispatch_rpc(server,"extensions/start",Dict("session_id"=>id,"action"=>"deactivate","name"=>"counter_extension"))["job_id"]
            @test timedwait(()->!isempty(server.approvals),30)==:ok
            ShenScope.dispatch_rpc(server,"extensions/cancel_job",Dict("session_id"=>id,"job_id"=>cancel))
            @test timedwait(()->ShenScope.dispatch_rpc(server,"extensions/job",Dict("session_id"=>id,"job_id"=>cancel))["status"]!="running",30)==:ok
            @test isempty(server.approvals)
            @test extension_inspect(control.registry,"counter_extension",ExtensionLifecycleFixtures.context(root))["phase"]=="active"
            context.permissions.rules[:read]=Deny
            hidden=ShenScope.dispatch_rpc(server,"extensions/job",Dict("session_id"=>id,"job_id"=>job))
            @test hidden["result"]===nothing && hidden["result_hidden_by_permission"]
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"extensions/query",Dict("session_id"=>id))
        finally
            ShenScope.stop_server!(server)
        end
    end
end
