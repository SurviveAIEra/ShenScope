@testset "Security RPC binds approval, jobs, revocation and configuration lifecycle" begin
    mktempdir() do root
        path=joinpath(root,"config.toml")
        write(path,"[permissions]\nread='allow'\nprocess='ask'\nedit='deny'\nnetwork='deny'\npersistence='allow'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=path,output=IOBuffer(),
            provider_factory=server->MockProvider([response("unused")]))
        try
            dispatch_rpc(server,"initialize",Dict())
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            query=dispatch_rpc(server,"security/query",Dict("session_id"=>owner))
            @test query["policy"]["backend"]=="host" && query["bubblewrap_probe"]===nothing
            old_security=ShenScope.server_security_tool(server)
            @test isempty(old_security.manager.probes) && isempty(server.approvals)
            @test_throws RPCFault dispatch_rpc(server,"security/query",Dict("session_id"=>owner,"unknown"=>1))
            first_job=dispatch_rpc(server,"security/start",Dict("session_id"=>owner,"action"=>"probe"))["job_id"]
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            request=first(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>foreign,"request_id"=>request,"decision"=>"once"))
            @test_throws ShenScopeError dispatch_rpc(server,"security/job",Dict("session_id"=>foreign,"job_id"=>first_job))
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"blocked"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>owner,"title"=>"blocked"))
            snapshot=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>"once"))
            job=execution_await_job(server,first_job)
            @test job.status==:complete && job.result["state"] in ("available","blocked","unconfirmed","unsupported_platform")
            @test isempty(server.approvals) && !job.result["os_isolation"]
            server.contexts[owner].permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"security/job",Dict("session_id"=>owner,"job_id"=>first_job))
            @test hidden["result"]===nothing && hidden["result_hidden_by_permission"]
            @test_throws ShenScopeError dispatch_rpc(server,"security/query",Dict("session_id"=>owner))
            dispatch_rpc(server,"security/cancel_job",Dict("session_id"=>owner,"job_id"=>first_job))
            server.contexts[owner].permissions.rules[:read]=Allow
            second_job=dispatch_rpc(server,"security/start",Dict("session_id"=>owner,"action"=>"probe"))["job_id"]
            @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
            dispatch_rpc(server,"security/cancel_job",Dict("session_id"=>owner,"job_id"=>second_job))
            cancelled=execution_await_job(server,second_job)
            @test cancelled.status==:cancelled && isempty(server.approvals)
            old_memory=ShenScope.server_memory_tool(server)
            ctx=ShenScope.server_context(server,owner)
            execute(old_memory,Dict("action"=>"put","key"=>"lifecycle","content"=>"Retained fact","expected_version"=>0),ctx;user_requested=true)
            execute(old_memory,Dict("action"=>"retrieve","query"=>"Retained"),ctx)
            @test !isempty(old_memory.manager.indexes)
            next=deepcopy(snapshot["value"]);next["sandbox"]=Dict("backend"=>"bubblewrap","network"=>"closed","filesystem"=>"read_only")
            dispatch_rpc(server,"config/set",Dict("value"=>next,"expected_sha256"=>snapshot["sha256"]))
            @test old_memory.manager.closed && old_security.manager.closed
            fresh_memory=ShenScope.server_memory_tool(server);fresh_security=ShenScope.server_security_tool(server)
            @test fresh_memory!==old_memory && fresh_security!==old_security
            @test !fresh_memory.manager.closed && !fresh_security.manager.closed
            executor=ShenScope.server_task_tool(server).manager.executor
            @test executor.tools["memory"]===fresh_memory && executor.tools["security"]===fresh_security
            @test dispatch_rpc(server,"security/query",Dict("session_id"=>owner))["policy"]["backend"]=="bubblewrap"
            @test dispatch_rpc(server,"memory/query",Dict("session_id"=>owner))["live"]==1
            ctx=ShenScope.server_context(server,owner)
            @test ctx.sandbox isa ShenScope.BubblewrapSandbox
            @test execute(fresh_memory,Dict("action"=>"get","key"=>"lifecycle"),ctx)["value"]["content"]=="Retained fact"
            saved=read(path,String);current=dispatch_rpc(server,"config/get",Dict())
            invalid=deepcopy(current["value"]);invalid["sandbox"]=Dict("backend"=>"invalid")
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>invalid,"expected_sha256"=>current["sha256"]))
            @test read(path,String)==saved && !fresh_memory.manager.closed && !fresh_security.manager.closed
            next["sandbox"]=Dict("backend"=>"host")
            dispatch_rpc(server,"config/set",Dict("value"=>next,"expected_sha256"=>current["sha256"]))
            @test dispatch_rpc(server,"memory/query",Dict("session_id"=>owner))["live"]==1
            @test dispatch_rpc(server,"security/query",Dict("session_id"=>owner))["policy"]["backend"]=="host"
            ctx=ShenScope.server_context(server,owner);ctx.permissions.rules[:process]=Allow
            process=only(tool for tool in server.tools if tool isa ProcessTool)
            handle=ShenScope.start_process!(process.manager,["/usr/bin/python3","-c","import time;time.sleep(10)"],ctx;emit_output=false)
            current=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>next,"expected_sha256"=>current["sha256"]))
            @test !ShenScope.server_memory_tool(server).manager.closed
            cleanup_processes!(process.manager,owner)
            @test handle.terminated
            dispatch_rpc(server,"config/set",Dict("value"=>next,"expected_sha256"=>current["sha256"]))
            @test !ShenScope.server_security_tool(server).manager.closed
        finally
            stop_server!(server)
        end
    end
end
