function hooks_protocol_server(root)
    argv=hook_script(root,"import sys,json; json.load(sys.stdin); print('{}')")
    path=hook_file(root,[hook_entry(argv=argv)])
    config=deepcopy(ShenScope.DEFAULT_CONFIG)
    config["hooks"]=Dict("project_files"=>["hooks.toml"],"user_files"=>[])
    config_path=joinpath(root,"config.toml");save_config!(config;path=config_path)
    server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config_path,output=IOBuffer(),provider_factory=server->MockProvider([response("Done")]))
    dispatch_rpc(server,"initialize",Dict())
    server,path
end

function await_hook_job(server,id)
    manager=ShenScope.server_hooks_tool(server).manager
    @test timedwait(()->manager.jobs[id].status != :running,15) == :ok
    manager.jobs[id]
end

@testset "Hook RPC scopes command approval, cancellation and source-opening proof" begin
    mktempdir() do root
        server,path=hooks_protocol_server(root)
        try
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            other=dispatch_rpc(server,"sessions/create",Dict())["id"]
            @test !dispatch_rpc(server,"hooks/query",Dict("session_id"=>owner))["indexed"]
            listed=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"list"))
            @test length(await_hook_job(server,listed["job_id"]).result["hooks"]) == 1
            @test_throws ShenScopeError dispatch_rpc(server,"hooks/job",Dict("session_id"=>other,"job_id"=>listed["job_id"]))
            tested=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"test","name"=>"guard"))
            @test timedwait(()->!isempty(server.approvals),15) == :ok
            request=first(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>other,"request_id"=>request,"decision"=>"once"))
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"concurrent"))
            snapshot=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>"once"))
            @test await_hook_job(server,tested["job_id"]).result["status"] == "complete"
            query=dispatch_rpc(server,"hooks/query",Dict("session_id"=>owner))
            @test query["hooks"][1]["recent"]["status"] == "complete"
            @test dispatch_rpc(server,"hooks/query",Dict("session_id"=>other))["hooks"][1]["recent"] === nothing
            opened=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"source","name"=>"guard"))
            @test await_hook_job(server,opened["job_id"]).result["path"] == path
            @test_throws ShenScopeError dispatch_rpc(server,"hooks/source_path",Dict("session_id"=>other,"job_id"=>opened["job_id"]))
            @test dispatch_rpc(server,"hooks/source_path",Dict("session_id"=>owner,"job_id"=>opened["job_id"]))["path"] == path
            @test_throws ShenScopeError dispatch_rpc(server,"hooks/source_path",Dict("session_id"=>owner,"job_id"=>opened["job_id"]))
            stale=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"source","name"=>"guard"));await_hook_job(server,stale["job_id"])
            write(path,read(path,String)*"\n# source changed\n")
            @test_throws ShenScopeError dispatch_rpc(server,"hooks/source_path",Dict("session_id"=>owner,"job_id"=>stale["job_id"]))
            job=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"test","name"=>"guard"))
            @test await_hook_job(server,job["job_id"]).result["status"] == "failed"
            reload=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"reload"));await_hook_job(server,reload["job_id"])
            cancelled=dispatch_rpc(server,"hooks/start",Dict("session_id"=>owner,"action"=>"test","name"=>"guard"))
            @test timedwait(()->!isempty(server.approvals),15) == :ok
            dispatch_rpc(server,"hooks/cancel_job",Dict("session_id"=>owner,"job_id"=>cancelled["job_id"]))
            @test await_hook_job(server,cancelled["job_id"]).status == :cancelled
            @test isempty(server.approvals)
            @test !iscancelled(server.contexts[owner].cancellation)
            @test isempty(ShenScope.server_hooks_tool(server).manager.process.handles)
            snapshot=dispatch_rpc(server,"config/get",Dict())
            dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            @test isempty(ShenScope.server_hooks_tool(server).manager.jobs)
        finally
            stop_server!(server)
        end
    end
end
