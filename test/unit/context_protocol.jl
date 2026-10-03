function await_context_job(server, id; timeout=30.0)
    manager=ShenScope.server_context_tool(server).manager
    result=timedwait(()->manager.jobs[id].status!=:running,timeout;pollint=0.01)
    result==:ok || error("Context fixture operation timed out")
    manager.jobs[id]
end

@testset "Context RPC ownership, permissions, asynchronous cancellation and CAS" begin
    mktempdir() do root
        configuration=joinpath(root,"config.toml")
        write(configuration,"[permissions]\nread='ask'\npersistence='ask'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=configuration,output=IOBuffer(),provider_factory=server->MockProvider(Any[response("unused")]))
        dispatch_rpc(server,"initialize",Dict())
        owner=dispatch_rpc(server,"sessions/create",Dict("title"=>"Context owner"))["id"]
        foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Foreign"))["id"]
        @test_throws ShenScopeError dispatch_rpc(server,"context/query",Dict("session_id"=>owner))
        started=dispatch_rpc(server,"context/start",Dict("session_id"=>owner,"action"=>"status"))
        @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
        @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"busy"))
        @test_throws ShenScopeError dispatch_rpc(server,"context/start",Dict("session_id"=>owner,"action"=>"status"))
        snapshot=dispatch_rpc(server,"config/get",Dict())
        @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
        @test_throws ShenScopeError dispatch_rpc(server,"context/job",Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
        approval=first(keys(server.approvals))
        dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>approval,"decision"=>"session"))
        job=await_context_job(server,started["job_id"])
        @test job.status==:complete
        @test job.result["session_id"]==owner
        @test dispatch_rpc(server,"context/query",Dict("session_id"=>owner))["messages"]==0
        write(joinpath(root,"AGENTS.md"),"Permissioned instructions")
        next=dispatch_rpc(server,"context/start",Dict("session_id"=>owner,"action"=>"instructions"))
        @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
        dispatch_rpc(server,"context/cancel_job",Dict("session_id"=>owner,"job_id"=>next["job_id"]))
        cancelled=await_context_job(server,next["job_id"])
        @test cancelled.status==:cancelled
        @test !iscancelled(server.contexts[owner].cancellation)
        @test isempty(server.approvals)
        updated=dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
        @test haskey(updated,"sha256")
        @test isempty(ShenScope.server_context_tool(server).manager.jobs)
        @test_throws ShenScopeError dispatch_rpc(server,"context/start",Dict("session_id"=>owner,"action"=>"source","message"=>true))
        stop_server!(server)
    end
end

@testset "Manual context checkpoints are shared by RPC and subsequent agent runs" begin
    mktempdir() do root
        config=joinpath(root,"config.toml");write(config,"[permissions]\npersistence='allow'\n")
        provider=MockProvider(Any[response("After compact")])
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer(),provider_factory=server->provider)
        dispatch_rpc(server,"initialize",Dict())
        owner=dispatch_rpc(server,"sessions/create",Dict("title"=>"Compact"))["id"]
        ctx=context_fixture(root;session_id=owner)
        session=load_session(server.state_dir,owner);context_transcript!(session;rounds=24,width=80)
        original=length(session.messages)
        job_id=dispatch_rpc(server,"context/start",Dict("session_id"=>owner,"action"=>"compact"))["job_id"]
        job=await_context_job(server,job_id)
        @test job.status==:complete
        @test job.result["compacted"]
        @test load_session(server.state_dir,owner).metadata["context_checkpoint"]["id"]==job.result["checkpoint"]["id"]
        @test dispatch_rpc(server,"context/query",Dict("session_id"=>owner))["messages"]==original
        dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"Continue"))
        @test timedwait(()->isempty(server.runs),30;pollint=0.01)==:ok
        @test load_session(server.state_dir,owner).status==:complete
        @test !isempty(provider.requests)
        @test any(message->haskey(message.native,"context_checkpoint"),only(provider.requests).messages)
        stop_server!(server)
    end
end
