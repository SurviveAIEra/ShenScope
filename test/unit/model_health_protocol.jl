@testset "Model health RPC reflects live runtime and enforces reset permission, CAS and scope" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[provider]\nendpoint='http://127.0.0.1:1'\n[permissions]\nread='allow'\nnetwork='ask'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            hello=dispatch_rpc(server,"initialize",Dict())
            @test hello["capabilities"]["model_health"]
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            provider=server.provider_factory(server)
            ctx=RuntimeContext(root;session_id=owner,state_dir=server.state_dir)
            credentials=ShenScope.CredentialSnapshot(provider.credential_lookup(provider.config.key_env))
            scope=ShenScope.model_circuit_key(provider,credentials,ctx)
            lease=ShenScope.acquire_model_circuit!(provider.runtime.circuits,scope,provider.runtime.circuit_policy)
            ShenScope.settle_model_circuit!(provider.runtime.circuits,lease,:failure;code=:server)
            snapshot=dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["health"]
            @test snapshot["failures"] == 1 && snapshot["consecutive_failures"] == 1
            @test dispatch_rpc(server,"models/query",Dict("session_id"=>foreign))["health"]["revision"] == snapshot["revision"]
            started=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>snapshot["revision"]))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
            @test_throws ShenScopeError dispatch_rpc(server,"models/cancel_job",Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
            approve_model_rpc(server,owner;decision="deny")
            @test await_model_job(server,started["job_id"]).error_code == :permission
            @test dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["health"]["revision"] == snapshot["revision"]
            reset=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>snapshot["revision"]))
            approve_model_rpc(server,owner)
            completed=await_model_job(server,reset["job_id"])
            @test completed.status == :complete && completed.result["reset"]
            @test completed.result["consecutive_failures"] == 0 && !completed.result["reset_is_health_probe"]
            stale=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>snapshot["revision"]))
            approve_model_rpc(server,owner)
            @test await_model_job(server,stale["job_id"]).error_code == :conflict
            view=dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["health"]
            lease=ShenScope.acquire_model_circuit!(provider.runtime.circuits,scope,provider.runtime.circuit_policy)
            active=dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["health"]
            blocked=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>active["revision"]))
            approve_model_rpc(server,owner)
            @test await_model_job(server,blocked["job_id"]).error_code == :conflict
            ShenScope.settle_model_circuit!(provider.runtime.circuits,lease,:neutral;code=:cancelled)
            current=dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["health"]
            clear=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>current["revision"],"clear_history"=>true))
            approve_model_rpc(server,owner)
            @test await_model_job(server,clear["job_id"]).result["cleared"]
            @test isempty(provider.runtime.circuits.entries)
            tool=ShenScope.server_models_tool(server)
            @test tool.provider.runtime.retry_policy === provider.runtime.retry_policy
            @test_throws ShenScopeError dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"reset_health","expected_revision"=>true))
        finally
            stop_server!(server)
        end
    end
end
