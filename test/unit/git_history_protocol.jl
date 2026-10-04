function history_rpc_wait(server, session_id, job_id;approve=true)
    answered = Set{String}()
    deadline = time() + 90
    while time() < deadline
        job = dispatch_rpc(server,"project/job",Dict("session_id"=>session_id,"job_id"=>job_id))
        job["status"] == "running" || return job, length(answered)
        if approve
            requests = lock(server.mutex) do; collect(keys(server.approvals)); end
            for request in requests
                request in answered && continue
                dispatch_rpc(server,"permissions/respond",Dict("session_id"=>session_id,"request_id"=>request,"decision"=>"once"))
                push!(answered,request)
            end
        end
        sleep(0.01)
    end
    error("Git history RPC fixture exceeded deadline")
end

@testset "Project RPC owns history jobs, exact approvals and child cancellation" begin
    mktempdir() do root
        ids, _ = history_fixture_repository(root)
        backend = TreeSitterBackend()
        server = CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            ctx = history_fixture_context(root;state_dir=server.state_dir)
            state = build!(backend,ctx)
            tool = ShenScope.server_project_tool(server)
            tool.manager.backends["tree_sitter"] = backend
            tool.manager.states[digest(root)*":tree_sitter"] = state
            server.config["permissions"]["persistence"] = "allow"
            server.config["permissions"]["network"] = "deny"
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            owner = dispatch_rpc(server,"sessions/create",Dict("title"=>"History evidence"))["id"]
            foreign = dispatch_rpc(server,"sessions/create",Dict("title"=>"Other session"))["id"]
            start = dispatch_rpc(server,"project/start",Dict("session_id"=>owner,"action"=>"git_cochange",
                "backend"=>"tree_sitter","paths"=>["a.jl"],"bulk_threshold"=>2))
            @test_throws ShenScopeError dispatch_rpc(server,"project/job",Dict("session_id"=>foreign,"job_id"=>start["job_id"]))
            @test_throws ShenScopeError dispatch_rpc(server,"project/cancel",Dict("session_id"=>foreign,"job_id"=>start["job_id"]))
            result, approvals = history_rpc_wait(server,owner,start["job_id"])
            @test result["status"] == "complete" && approvals == 5
            @test only(result["result"]["candidates"])["file"] == "b.jl"
            @test result["result"]["coverage"]["head"] == last(ids)
            @test isempty(load_session(server.state_dir,owner).messages)
            @test isempty(server.approvals)
            @test_throws RPCFault dispatch_rpc(server,"project/query",Dict("action"=>"risk"))
            risk = dispatch_rpc(server,"project/start",Dict("session_id"=>owner,"action"=>"risk","paths"=>["a.jl"],"bulk_threshold"=>2))
            report, approvals = history_rpc_wait(server,owner,risk["job_id"])
            @test report["status"] == "complete" && approvals == 5
            @test only(report["result"]["candidates"])["risk_kind"] == "heuristic_review_priority"
            canceled = dispatch_rpc(server,"project/start",Dict("session_id"=>owner,"action"=>"risk"))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
            dispatch_rpc(server,"project/cancel",Dict("session_id"=>owner,"job_id"=>canceled["job_id"]))
            failed, _ = history_rpc_wait(server,owner,canceled["job_id"];approve=false)
            @test failed["status"] == "failed" && isempty(server.approvals)
            @test !iscancelled(server.contexts[owner].cancellation)
            @test_throws ShenScopeError dispatch_rpc(server,"project/start",Dict("session_id"=>owner,"action"=>"risk","history_limit"=>513))
        finally
            stop_server!(server)
            backend_close!(backend)
        end
    end
end
