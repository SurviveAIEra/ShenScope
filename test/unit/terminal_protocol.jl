@testset "Terminal RPC grants, jobs, output and cancellation retain conversation ownership" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\nprocess='ask'\npersistence='allow'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            ShenScope.dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            id=ShenScope.dispatch_rpc(server,"sessions/create",Dict("title"=>"Terminal"))["id"]
            foreign=ShenScope.dispatch_rpc(server,"sessions/create",Dict("title"=>"Foreign"))["id"]
            job=ShenScope.dispatch_rpc(server,"terminal/start",Dict("session_id"=>id,"action"=>"start",
                "argv"=>[TERMINAL_PYTHON,"-u","-c",TERMINAL_ECHO_PROGRAM],"timeout"=>30))["job_id"]
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"terminal/job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"terminal/cancel_job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"agent/start",Dict("session_id"=>id,"prompt"=>"Work"))
            request=only(keys(server.approvals))
            ShenScope.dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"once"))
            result=()->ShenScope.dispatch_rpc(server,"terminal/job",Dict("session_id"=>id,"job_id"=>job))
            @test timedwait(()->result()["status"]!="running",30;pollint=0.01)==:ok
            @test result()["status"]=="complete"
            handle=result()["result"]["handle"]
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"terminal/query",Dict("session_id"=>foreign,"action"=>"poll","handle"=>handle))
            @test isempty(ShenScope.dispatch_rpc(server,"terminal/query",Dict("session_id"=>foreign,"action"=>"list"))["terminals"])
            server.contexts[id].permissions.rules[:read]=Deny
            @test_throws ShenScopeError ShenScope.dispatch_rpc(server,"terminal/query",Dict("session_id"=>id,"action"=>"poll","handle"=>handle))
            @test result()["result"]===nothing && result()["result_hidden_by_permission"]
            server.contexts[id].permissions.rules[:read]=Allow
            next=ShenScope.dispatch_rpc(server,"terminal/start",Dict("session_id"=>id,"action"=>"write","handle"=>handle,"input"=>"hidden\n"))["job_id"]
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            ShenScope.dispatch_rpc(server,"terminal/cancel_job",Dict("session_id"=>id,"job_id"=>next))
            @test timedwait(()->ShenScope.dispatch_rpc(server,"terminal/job",Dict("session_id"=>id,"job_id"=>next))["status"]!="running",5;pollint=0.01)==:ok
            @test isempty(server.approvals)
            view=ShenScope.dispatch_rpc(server,"terminal/query",Dict("session_id"=>id,"action"=>"poll","handle"=>handle))
            @test !occursin("hidden",view["output"]["text"]) && view["running"]
        finally
            ShenScope.stop_server!(server)
        end
        @test isempty(ShenScope.server_terminal_tool(server).manager.handles)
    end
end
