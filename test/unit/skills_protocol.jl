function skills_protocol_server(root)
    path = skill_fixture(joinpath(root, "skills"), "review-code")
    config = deepcopy(ShenScope.DEFAULT_CONFIG)
    config["skills"] = Dict("project_roots" => ["skills"], "user_roots" => [])
    config_path = joinpath(root, "config.toml"); save_config!(config; path = config_path)
    server = CoreServer(root; state_dir = joinpath(root, "state"), config_file = config_path, output = IOBuffer(),
        provider_factory = server -> MockProvider([response("Done")]))
    dispatch_rpc(server, "initialize", Dict())
    server, path
end

function await_skills_job(server, id)
    manager = ShenScope.server_skills_tool(server).manager
    @test timedwait(() -> manager.jobs[id].status != :running, 10) == :ok
    manager.jobs[id]
end

@testset "Skills RPC scopes approvals, durable activation and source-opening proof" begin
    mktempdir() do root
        server, path = skills_protocol_server(root)
        try
            owner = dispatch_rpc(server, "sessions/create", Dict())["id"]
            foreign = dispatch_rpc(server, "sessions/create", Dict())["id"]
            @test !dispatch_rpc(server, "skills/query", Dict("session_id" => owner))["indexed"]
            start = dispatch_rpc(server, "skills/start", Dict("session_id" => owner, "action" => "list"))
            @test length(await_skills_job(server, start["job_id"]).result["skills"]) == 1
            @test_throws ShenScopeError dispatch_rpc(server, "skills/job", Dict("session_id" => foreign, "job_id" => start["job_id"]))
            activation = dispatch_rpc(server, "skills/start", Dict("session_id" => owner, "action" => "activate", "name" => "review-code", "arguments" => "RPC 中文"))
            @test timedwait(() -> !isempty(server.approvals), 10) == :ok
            request = first(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server, "permissions/respond", Dict("session_id" => foreign, "request_id" => request, "decision" => "once"))
            @test_throws ShenScopeError dispatch_rpc(server, "agent/start", Dict("session_id" => owner, "prompt" => "Concurrent mutation"))
            snapshot = dispatch_rpc(server, "config/get", Dict())
            @test_throws ShenScopeError dispatch_rpc(server, "config/set", Dict("value" => snapshot["value"], "expected_sha256" => snapshot["sha256"]))
            dispatch_rpc(server, "permissions/respond", Dict("session_id" => owner, "request_id" => request, "decision" => "session"))
            @test occursin("RPC 中文", await_skills_job(server, activation["job_id"]).result["body"])
            @test load_session(server.state_dir, owner).metadata["active_skills"][1]["arguments"] == "RPC 中文"
            @test dispatch_rpc(server, "skills/query", Dict("session_id" => owner))["skills"][1]["loaded"]
            @test !dispatch_rpc(server, "skills/query", Dict("session_id" => foreign))["skills"][1]["loaded"]
            source = dispatch_rpc(server, "skills/start", Dict("session_id" => owner, "action" => "source", "name" => "review-code"))
            @test await_skills_job(server, source["job_id"]).result["path"] == path
            @test_throws ShenScopeError dispatch_rpc(server, "skills/source_path", Dict("session_id" => foreign, "job_id" => source["job_id"]))
            @test dispatch_rpc(server, "skills/source_path", Dict("session_id" => owner, "job_id" => source["job_id"]))["path"] == path
            @test_throws ShenScopeError dispatch_rpc(server, "skills/source_path", Dict("session_id" => owner, "job_id" => source["job_id"]))
            changed = dispatch_rpc(server, "skills/start", Dict("session_id" => owner, "action" => "source", "name" => "review-code"))
            await_skills_job(server, changed["job_id"])
            write(path, read(path, String) * "\nchanged")
            @test_throws ShenScopeError dispatch_rpc(server, "skills/source_path", Dict("session_id" => owner, "job_id" => changed["job_id"]))
            @test_throws ShenScopeError dispatch_rpc(server, "skills/source_path", Dict("session_id" => owner, "job_id" => activation["job_id"]))
            snapshot = dispatch_rpc(server, "config/get", Dict())
            dispatch_rpc(server, "config/set", Dict("value" => snapshot["value"], "expected_sha256" => snapshot["sha256"]))
            @test isempty(ShenScope.server_skills_tool(server).manager.jobs)
            @test isempty(ShenScope.server_skills_tool(server).manager.active)
        finally
            stop_server!(server)
        end
    end
end

@testset "Skills job cancellation drains approval and retains peer policy" begin
    mktempdir() do root
        server, path = skills_protocol_server(root)
        try
            owner = dispatch_rpc(server, "sessions/create", Dict())["id"]
            job = dispatch_rpc(server, "skills/start", Dict("session_id" => owner, "action" => "activate", "name" => "review-code"))
            @test timedwait(() -> !isempty(server.approvals), 10) == :ok
            dispatch_rpc(server, "skills/cancel_job", Dict("session_id" => owner, "job_id" => job["job_id"]))
            @test await_skills_job(server, job["job_id"]).status == :cancelled
            @test isempty(server.approvals)
            @test isempty(get(load_session(server.state_dir, owner).metadata, "active_skills", []))
            @test !iscancelled(server.contexts[owner].cancellation)
        finally
            stop_server!(server)
        end
    end
end
