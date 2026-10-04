function memory_protocol_fixture(root)
    path=joinpath(root,"config.toml")
    write(path,"[permissions]\nread='ask'\npersistence='ask'\nprocess='deny'\nnetwork='deny'\n")
    server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=path,output=IOBuffer(),
        provider_factory=server->MockProvider([response("unused")]))
    dispatch_rpc(server,"initialize",Dict())
    server
end

function await_memory_job(server,id)
    manager=ShenScope.server_memory_tool(server).manager
    @test timedwait(()->manager.operations.jobs[id].status!=:running,30;pollint=0.01)==:ok
    manager.operations.jobs[id]
end

function approve_memory_job(server,owner;decision="once")
    @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
    request=first(keys(server.approvals))
    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>decision))
    request
end

@testset "Memory RPC approvals, CAS, scope, revocation and lifecycle barriers" begin
    mktempdir() do root
        server=memory_protocol_fixture(root)
        try
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            @test_throws ShenScopeError dispatch_rpc(server,"memory/query",Dict("session_id"=>owner))
            put=dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"put","namespace"=>"notes",
                "key"=>"julia","content"=>"中文代码图 evidence","tags"=>["core"],"expected_version"=>0))
            @test_throws ShenScopeError dispatch_rpc(server,"memory/job",Dict("session_id"=>foreign,"job_id"=>put["job_id"]))
            @test_throws ShenScopeError dispatch_rpc(server,"memory/cancel_job",Dict("session_id"=>foreign,"job_id"=>put["job_id"]))
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"busy"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>owner,"title"=>"busy"))
            @test_throws ShenScopeError dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"status"))
            config=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>config["value"],"expected_sha256"=>config["sha256"]))
            request=first(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>foreign,"request_id"=>request,"decision"=>"once"))
            approve_memory_job(server,owner)
            @test await_memory_job(server,put["job_id"]).status==:complete
            view=dispatch_rpc(server,"memory/job",Dict("session_id"=>owner,"job_id"=>put["job_id"]))
            @test view["result"]["version"]==1
            @test view["result"]["value"]["source"]=="user"
            get=dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"get","namespace"=>"notes","key"=>"julia"))
            approve_memory_job(server,owner)
            @test await_memory_job(server,get["job_id"]).result["entry"]["value"]["content"]=="中文代码图 evidence"
            search=dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"retrieve","namespace"=>"notes","query"=>"代码图"))
            approve_memory_job(server,owner)
            @test await_memory_job(server,search["job_id"]).result["items"][1]["key"]=="julia"
            @test isempty(server.approvals)
            server.contexts[owner].permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"memory/job",Dict("session_id"=>owner,"job_id"=>search["job_id"]))
            @test hidden["result"]===nothing && hidden["result_hidden_by_permission"]
            @test dispatch_rpc(server,"memory/cancel_job",Dict("session_id"=>owner,"job_id"=>search["job_id"]))["result"]===nothing
            server.contexts[owner].permissions.rules[:read]=Ask
            pending=dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"retrieve","query"=>"missing"))
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            dispatch_rpc(server,"memory/cancel_job",Dict("session_id"=>owner,"job_id"=>pending["job_id"]))
            @test await_memory_job(server,pending["job_id"]).status==:cancelled
            @test isempty(server.approvals)
            server.contexts[owner].permissions.rules[:read]=Allow
            server.contexts[foreign].permissions.rules[:read]=Allow
            @test dispatch_rpc(server,"memory/query",Dict("session_id"=>owner,"namespace"=>"notes"))["live"]==1
            @test dispatch_rpc(server,"memory/query",Dict("session_id"=>foreign,"scope"=>"session","namespace"=>"notes"))["live"]==0
            @test_throws RPCFault dispatch_rpc(server,"memory/query",Dict("session_id"=>owner,"action"=>"get"))
            @test_throws ShenScopeError dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"delete","key"=>"julia"))
            stale=dispatch_rpc(server,"memory/start",Dict("session_id"=>owner,"action"=>"put","namespace"=>"notes",
                "key"=>"julia","content"=>"stale","expected_version"=>0))
            approve_memory_job(server,owner)
            @test await_memory_job(server,stale["job_id"]).error_code==:conflict
        finally
            stop_server!(server)
        end
        @test ShenScope.server_memory_tool(server).manager.closed
        @test isempty(ShenScope.server_memory_tool(server).manager.operations.jobs)
    end
end
