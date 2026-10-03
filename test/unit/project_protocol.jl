@testset "Project RPC lifecycle, approvals and responsive cancellation" begin
    mktempdir() do root
        write(joinpath(root,"sample.go"),"package p\nfunc A() int { return 1 }\nfunc TestA() int { return A() }\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            @test_throws RPCFault dispatch_rpc(server,"project/backends",Dict())
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            @test length(dispatch_rpc(server,"project/backends",Dict()))==4
            @test dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast"))["indexed"]==false
            session=dispatch_rpc(server,"sessions/create",Dict("title"=>"Project graph"));id=session["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Separate conversation"))["id"]
            started=dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"go_ast","action"=>"build"))
            jobid=started["job_id"]
            @test started["started"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/job",Dict("job_id"=>jobid,"session_id"=>foreign))
            @test_throws ShenScopeError dispatch_rpc(server,"project/cancel",Dict("job_id"=>jobid,"session_id"=>foreign))
            @test_throws RPCFault dispatch_rpc(server,"project/job",Dict("job_id"=>jobid))
            @test_throws ShenScopeError dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"go_ast","action"=>"build"))
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast"))
            snapshot=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>snapshot["value"],"expected_sha256"=>snapshot["sha256"]))
            deadline=time()+30;approvals=0;answered=Set{String}()
            while dispatch_rpc(server,"project/job",Dict("job_id"=>jobid,"session_id"=>id))["status"]=="running" && time()<deadline
                for request in collect(keys(server.approvals))
                    request in answered && continue
                    @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>string(Base.UUID(1)),"request_id"=>request,"decision"=>"once"))
                    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"once"));approvals+=1;push!(answered,request)
                    @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"once"))
                end
                sleep(0.02)
            end
            @test approvals>=2
            @test dispatch_rpc(server,"project/job",Dict("job_id"=>jobid,"session_id"=>id))["status"]=="complete"
            status=dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast"))
            @test status["files"]==1
            @test status["capabilities"]["types"]==false
            result=dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast","action"=>"search","query"=>"TestA"))
            @test first(result["symbols"])["name"]=="TestA"
            # A fresh manager replays Core facts without starting a parser process.
            manager=ShenScope.server_project_tool(server).manager
            ShenScope.cleanup_projects!(manager)
            empty!(manager.states);empty!(manager.backends)
            status=dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast"))
            @test status["files"]==1
            @test manager.backends["go_ast"].worker.process===nothing
            server.config["permissions"]["read"]="deny"
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast"))
            @test dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast","session_id"=>id))["files"]==1
            server.config["permissions"]["read"]="allow"
            state=first(values(manager.states));bytes=filesize(state.journal.path)
            state.journal_bytes=ShenScope.MAX_PROJECT_JOURNAL_BYTES
            @test_throws ShenScopeError ShenScope.persist_delta!(state,Dict{String,Union{Nothing,ShenScope.FileFacts}}())
            @test filesize(state.journal.path)==bytes
            state.journal_bytes=bytes
            @test isempty(server.approvals)
            @test isempty(load_session(server.state_dir,id).messages)
            started=dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"tree_sitter","action"=>"build"))
            dispatch_rpc(server,"project/cancel",Dict("job_id"=>started["job_id"],"session_id"=>id))
            @test timedwait(()->dispatch_rpc(server,"project/job",Dict("job_id"=>started["job_id"],"session_id"=>id))["status"]!="running",10)==:ok
            @test dispatch_rpc(server,"project/job",Dict("job_id"=>started["job_id"],"session_id"=>id))["status"]=="failed"
            @test !iscancelled(server.contexts[id].cancellation)
            job=manager.jobs[started["job_id"]]
            @test job["context"].cancellation.parent===server.contexts[id].cancellation
            @test job["context"].budget===server.contexts[id].budget
            # A project child must cancel its own pending approval without
            # cancelling the conversation or waiting for the approval timeout.
            empty!(server.contexts[id].permissions.grants)
            started=dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"tree_sitter","action"=>"build"))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
            dispatch_rpc(server,"project/cancel",Dict("job_id"=>started["job_id"],"session_id"=>id))
            @test timedwait(()->dispatch_rpc(server,"project/job",Dict("job_id"=>started["job_id"],"session_id"=>id))["status"]=="failed",5;pollint=0.01)==:ok
            @test isempty(server.approvals)
            @test !iscancelled(server.contexts[id].cancellation)
            @test_throws RPCFault dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast","action"=>"unknown"))
        finally;stop_server!(server);end
    end
end
