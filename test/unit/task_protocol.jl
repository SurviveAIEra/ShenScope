function await_work_job(server, job_id; seconds = 20)
    manager = ShenScope.server_task_tool(server).manager
    deadline = time() + seconds
    while manager.jobs[job_id].status == :running && time() < deadline
        sleep(0.025)
    end
    manager.jobs[job_id]
end

@testset "Asynchronous task protocol, approvals and session ownership" begin
    mktempdir() do root
        write(joinpath(root, "source.txt"), "protocol\n")
        server = CoreServer(root; state_dir = joinpath(root, "state"), config_file = joinpath(root, "config.toml"), output = IOBuffer())
        dispatch_rpc(server, "initialize", Dict())
        owner = dispatch_rpc(server, "sessions/create", Dict())["id"]
        foreign = dispatch_rpc(server, "sessions/create", Dict())["id"]
        started = dispatch_rpc(server, "tasks/start", Dict("session_id" => owner, "action" => "create",
            "workflow_id" => "protocol", "definitions" => [ShenScope.work_spec_dict(read_work("read"))]))
        deadline = time() + 15
        while isempty(server.approvals) && time() < deadline; sleep(0.025); end
        @test length(server.approvals) == 1
        @test !isfile(joinpath(server.state_dir, "workflows", digest(server.root), "protocol.jsonl"))
        request = first(keys(server.approvals))
        @test_throws ShenScopeError dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => foreign, "decision" => "session"))
        dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => owner, "decision" => "session"))
        @test await_work_job(server, started["job_id"]).status == :complete
        status = dispatch_rpc(server, "tasks/query", Dict("session_id" => owner, "action" => "status", "workflow_id" => "protocol"))
        @test status["status"] == "ready"
        @test_throws ShenScopeError dispatch_rpc(server, "tasks/query", Dict("session_id" => foreign, "action" => "status", "workflow_id" => "protocol"))
        @test_throws ShenScopeError dispatch_rpc(server, "tasks/job", Dict("session_id" => foreign, "job_id" => started["job_id"]))
        running = dispatch_rpc(server, "tasks/start", Dict("session_id" => owner, "action" => "run", "workflow_id" => "protocol"))
        @test await_work_job(server, running["job_id"]).status == :complete
        result = dispatch_rpc(server, "tasks/query", Dict("session_id" => owner, "action" => "get", "workflow_id" => "protocol", "task_id" => "read", "materialize" => true))
        @test result["status"] == "succeeded"
        @test occursin("protocol", result["result"]["text"])
        @test !haskey(result, "token")
        @test_throws RPCFault dispatch_rpc(server, "tasks/query", Dict("session_id" => owner, "action" => "run", "workflow_id" => "protocol"))
        stop_server!(server)
        @test isempty(server.approvals)
    end
end

@testset "Task jobs block config replacement and drain owned processes" begin
    mktempdir() do root
        server = CoreServer(root; state_dir = joinpath(root, "state"), config_file = joinpath(root, "config.toml"), output = IOBuffer())
        server.config["permissions"]["persistence"] = "allow"
        server.config["permissions"]["process"] = "allow"
        dispatch_rpc(server, "initialize", Dict())
        owner = dispatch_rpc(server, "sessions/create", Dict())["id"]
        specification = WorkSpec("slow", :test, "process", Dict("action" => "run", "argv" => ["/bin/sh", "-c", "sleep 20"]))
        created = dispatch_rpc(server, "tasks/start", Dict("session_id" => owner, "action" => "create", "workflow_id" => "slow", "definitions" => [ShenScope.work_spec_dict(specification)]))
        @test await_work_job(server, created["job_id"]).status == :complete
        run = dispatch_rpc(server, "tasks/start", Dict("session_id" => owner, "action" => "run", "workflow_id" => "slow"))
        config = dispatch_rpc(server, "config/get", Dict())
        @test_throws ShenScopeError dispatch_rpc(server, "config/set", Dict("value" => config["value"], "expected_sha256" => config["sha256"]))
        @test_throws ShenScopeError dispatch_rpc(server, "tasks/start", Dict("session_id" => owner, "action" => "run", "workflow_id" => "slow"))
        sleep(0.2)
        dispatch_rpc(server, "tasks/cancel_job", Dict("session_id" => owner, "job_id" => run["job_id"]))
        @test await_work_job(server, run["job_id"]).status in (:cancelled, :complete)
        ctx = RuntimeContext(root; session_id = owner, state_dir = server.state_dir, permissions = PermissionPolicy(; rules = Dict(:read => Allow)))
        workflow = load_workflow(ctx, "slow")
        @test workflow.tasks["slow"].status == WorkUncertain
        stop_server!(server)
    end
end
