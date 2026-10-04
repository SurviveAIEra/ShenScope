function await_analyzer_job(server,id;timeout=60.0)
    manager = ShenScope.server_analyzers_tool(server).manager
    status = timedwait(()->manager.jobs[id].status != :running,timeout;pollint=0.01)
    status == :ok || error("Analyzer RPC fixture timed out")
    manager.jobs[id]
end

@testset "Analyzer RPC ownership, permissions, cancellation and configuration barriers" begin
    mktempdir() do root
        configuration = joinpath(root,"config.toml")
        write(configuration,"[permissions]\nread='ask'\ndynamic='ask'\nprocess='ask'\npersistence='ask'\n")
        server = CoreServer(root;state_dir=joinpath(root,"state"),config_file=configuration,output=IOBuffer(),
            provider_factory=server->MockProvider(Any[response("unused")]))
        try
            dispatch_rpc(server,"initialize",Dict())
            owner = dispatch_rpc(server,"sessions/create",Dict("title"=>"Analyzer owner"))["id"]
            foreign = dispatch_rpc(server,"sessions/create",Dict("title"=>"Foreign"))["id"]
            @test_throws ShenScopeError dispatch_rpc(server,"analyzers/query",Dict("session_id"=>owner))
            @test_throws RPCFault dispatch_rpc(server,"analyzers/query",Dict("session_id"=>owner,"unexpected"=>true))
            @test_throws RPCFault dispatch_rpc(server,"analyzers/unknown",Dict("session_id"=>owner))
            started = dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"status"))
            @test started["started"]
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
            @test_throws ShenScopeError dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"status"))
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"busy"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>owner,"title"=>"busy"))
            snapshot = dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            for method in ("analyzers/job","analyzers/cancel_job")
                @test_throws ShenScopeError dispatch_rpc(server,method,Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
                @test_throws RPCFault dispatch_rpc(server,method,Dict("session_id"=>owner,"job_id"=>started["job_id"],"unexpected"=>true))
            end
            request = first(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>foreign,"request_id"=>request,"decision"=>"session"))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>"session"))
            completed = await_analyzer_job(server,started["job_id"])
            @test completed.status == :complete
            @test completed.result["default_lifetime"] == "session"
            source = "selftest()=true\nanalyze(d,r)=Dict(\"value\"=>1)"
            next = dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"register","name"=>"rpc_check","source"=>source))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
            dispatch_rpc(server,"analyzers/cancel_job",Dict("session_id"=>owner,"job_id"=>next["job_id"]))
            cancelled = await_analyzer_job(server,next["job_id"])
            @test cancelled.status == :cancelled
            @test !iscancelled(server.contexts[owner].cancellation)
            @test isempty(server.approvals)
            manager = ShenScope.server_analyzers_tool(server).manager
            @test isempty(manager.records)
            server.contexts[owner].permissions.rules[:read] = Allow
            server.contexts[owner].permissions.rules[:dynamic] = Allow
            registered = dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"register","name"=>"rpc_check","source"=>source))
            candidate = await_analyzer_job(server,registered["job_id"])
            @test candidate.status == :complete
            catalog = dispatch_rpc(server,"analyzers/query",Dict("session_id"=>owner))
            @test catalog["session"]["total"] == 1
            @test catalog["project_active"]["rpc_check"] === nothing
            @test catalog["project_archive"]["total"] == 0
            @test_throws ShenScopeError dispatch_rpc(server,"analyzers/query",Dict("session_id"=>owner,"project_offset"=>true))
            inspected = dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"inspect","name"=>"rpc_check"))
            @test await_analyzer_job(server,inspected["job_id"]).result["source"] == source
            updated = dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            @test haskey(updated,"sha256")
            @test isempty(manager.jobs)
            @test isempty(manager.records)
            @test_throws ShenScopeError dispatch_rpc(server,"analyzers/start",Dict("session_id"=>owner,"action"=>"status","unexpected"=>true))
        finally
            stop_server!(server)
        end
    end
end
