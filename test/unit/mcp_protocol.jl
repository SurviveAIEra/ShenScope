function protocol_mcp_server(root)
    config = deepcopy(ShenScope.DEFAULT_CONFIG)
    script = abspath(joinpath(@__DIR__, "..", "fixtures", "mcp_server.py"))
    config["mcp"]["servers"]["fixture"] = Dict("argv" => ["python3", script], "timeout" => 0.3, "reconnect_attempts" => 0)
    path = joinpath(root, "config.toml")
    save_config!(config; path)
    server = CoreServer(root; state_dir = joinpath(root, "state"), config_file = path, output = IOBuffer())
    dispatch_rpc(server, "initialize", Dict())
    server
end

function await_mcp_job(server, id; seconds = 10)
    manager = ShenScope.server_mcp_tool(server).manager
    @test timedwait(() -> manager.jobs[id].status != :running, seconds) == :ok
    manager.jobs[id]
end

function await_mcp_approval(server)
    @test timedwait(() -> !isempty(server.approvals), 5) == :ok
    first(keys(server.approvals))
end

@testset "MCP async protocol keeps approvals, jobs and connections session scoped" begin
    mktempdir() do root
        server = protocol_mcp_server(root)
        try
            owner = dispatch_rpc(server, "sessions/create", Dict())["id"]
            foreign = dispatch_rpc(server, "sessions/create", Dict())["id"]
            @test dispatch_rpc(server, "mcp/query", Dict("session_id" => owner, "action" => "servers"))[1]["state"] == "disconnected"
            @test_throws RPCFault dispatch_rpc(server, "mcp/query", Dict("session_id" => owner, "action" => "connect", "server" => "fixture"))
            job = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "server" => "fixture", "action" => "connect"))["job_id"]
            for _ in 1:2
                request = await_mcp_approval(server)
                @test_throws ShenScopeError dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => foreign, "decision" => "session"))
                config = dispatch_rpc(server, "config/get", Dict())
                @test_throws ShenScopeError dispatch_rpc(server, "config/set", Dict("value" => config["value"], "expected_sha256" => config["sha256"]))
                dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => owner, "decision" => "session"))
                sleep(0.05)
            end
            @test await_mcp_job(server, job).status == :complete
            @test_throws ShenScopeError dispatch_rpc(server, "mcp/job", Dict("session_id" => foreign, "job_id" => job))
            @test dispatch_rpc(server, "mcp/query", Dict("session_id" => owner, "action" => "status", "server" => "fixture"))["state"] == "ready"
            ping = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "ping", "server" => "fixture"))
            @test await_mcp_job(server, ping["job_id"]).result["ok"]
            @test dispatch_rpc(server, "mcp/query", Dict("session_id" => foreign, "action" => "status", "server" => "fixture"))["state"] == "disconnected"
            started = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "tools", "server" => "fixture"))
            @test length(await_mcp_job(server, started["job_id"]).result) == 2
            called = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "call", "server" => "fixture", "name" => "echo/input", "arguments" => Dict("value" => "RPC")))
            request = await_mcp_approval(server)
            dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => owner, "decision" => "once"))
            @test await_mcp_job(server, called["job_id"]).result["structuredContent"]["echo"] == "RPC"
            denied = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "call", "server" => "fixture", "name" => "echo/input", "arguments" => Dict("value" => "deny")))
            request = await_mcp_approval(server)
            dispatch_rpc(server, "permissions/respond", Dict("request_id" => request, "session_id" => owner, "decision" => "deny"))
            @test await_mcp_job(server, denied["job_id"]).status == :failed
            cancelled = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "call", "server" => "fixture", "name" => "echo/input", "arguments" => Dict("value" => "cancel")))
            await_mcp_approval(server)
            dispatch_rpc(server, "mcp/cancel_job", Dict("session_id" => owner, "job_id" => cancelled["job_id"]))
            @test await_mcp_job(server, cancelled["job_id"]).status == :cancelled
            @test isempty(server.approvals)
            @test dispatch_rpc(server, "mcp/query", Dict("session_id" => owner, "action" => "status", "server" => "fixture"))["state"] == "ready"
            config = dispatch_rpc(server, "config/get", Dict())
            process = only(client for client in values(ShenScope.server_mcp_tool(server).manager.clients) if client.context.session_id == owner).transport.process
            dispatch_rpc(server, "config/set", Dict("value" => config["value"], "expected_sha256" => config["sha256"]))
            @test process_exited(process)
            @test isempty(ShenScope.server_mcp_tool(server).manager.clients)
            config = dispatch_rpc(server, "config/get", Dict())
            config["value"]["mcp"]["servers"]["fixture"]["enabled"] = false
            dispatch_rpc(server, "config/set", Dict("value" => config["value"], "expected_sha256" => config["sha256"]))
            @test dispatch_rpc(server, "mcp/query", Dict("session_id" => owner, "action" => "servers"))[1]["state"] == "disabled"
            disabled = dispatch_rpc(server, "mcp/start", Dict("session_id" => owner, "action" => "connect", "server" => "fixture"))
            @test await_mcp_job(server, disabled["job_id"]).status == :failed
        finally
            stop_server!(server)
        end
    end
end
