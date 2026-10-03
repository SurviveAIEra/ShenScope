mcp_find_tool_for_test(client) = only(item for item in mcp_catalog(client, :tools) if item["name"] == "echo/input")

@testset "MCP rejects invalid servers and preserves dirty catalogs" begin
    mktempdir() do root
        for mode in ("version", "bad_caps")
            client = mcp_fixture_client(mcp_fixture_context(root); mode, options = Dict("reconnect_attempts" => 0))
            try
                @test_throws ShenScopeError mcp_connect!(client)
                @test client.state == :failed
                @test client.transport.closed
            finally
                mcp_disconnect!(client)
            end
        end
        for mode in ("bad_schema", "cursor_cycle", "malformed", "oversize", "catalog_race")
            client = mcp_fixture_client(mcp_fixture_context(root); mode,
                options = Dict("reconnect_attempts" => 0, "max_message_bytes" => 8192))
            try
                mcp_connect!(client)
                @test_throws ShenScopeError mcp_catalog(client, :tools)
                @test client.catalogs[:tools].dirty
                @test isempty(client.catalogs[:tools].items)
                @test isempty(client.pending)
            finally
                mcp_disconnect!(client)
            end
        end
    end
end

@testset "MCP environment, permission, ownership and error isolation" begin
    mktempdir() do root
        withenv("SHENSCOPE_TEST_AMBIENT" => "must-not-reach-child", "FIXTURE_ENV_SOURCE" => "explicit-value") do
            ctx = mcp_fixture_context(root)
            client = mcp_fixture_client(ctx; options = Dict("environment_env" => [Dict("name" => "FIXTURE_BINDING", "env" => "FIXTURE_ENV_SOURCE")]))
            try
                mcp_connect!(client)
                result = mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "environment"))["structuredContent"]["echo"]
                @test result["explicit"] == "explicit-value"
                @test result["ambient"] === nothing
                cause = try mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "rpc_error")); nothing catch error; error end
                @test cause isa MCPRemoteError
                @test !occursin("FAKE_SECRET", sprint(showerror, cause))
                @test cause.data === nothing
                other = mcp_fixture_context(root)
                @test_throws ShenScopeError mcp_request!(client, "ping", Dict(), other)
                tool = MCPRemoteTool(client, mcp_find_tool_for_test(client))
                @test tool_name(tool) != "echo/input"
                @test execution_mode(tool) == :exclusive
                @test execute_call(tool, ToolCall(tool_name(tool), Dict("value" => 1, "mode" => "error")), ctx).ok == false
                push!(ctx.permissions.grants, (:mcp, ShenScope.mcp_permission_target(client.spec)))
                ctx.permissions.rules[:mcp] = Deny
                @test_throws ShenScopeError mcp_request!(client, "ping", Dict(), ctx)
                @test isempty(client.pending)
            finally
                mcp_disconnect!(client)
            end
        end
    end
end

@testset "MCP timeouts, cancellation, fencing and no tool replay" begin
    mktempdir() do root
        events = AgentEvent[]
        ctx = mcp_fixture_context(root; sink = event -> push!(events, event))
        log = joinpath(root, "methods.jsonl")
        client = mcp_fixture_client(ctx; log, options = Dict("timeout" => 0.2, "reconnect_attempts" => 1))
        try
            mcp_connect!(client)
            cause = try mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "slow")); nothing catch error; error end
            @test cause isa ShenScopeError && cause.code == :mcp_outcome_uncertain
            @test isempty(client.pending)
            @test mcp_request!(client, "ping") == Dict()
            child = child_context(ctx)
            task = @async try mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "slow"), child) catch error; error end
            @test timedwait(() -> !isempty(client.pending), 2) == :ok
            cancel!(child.cancellation)
            @test fetch(task).code == :mcp_outcome_uncertain
            @test client.state == :ready
            generation = client.generation
            old_callback = client.transport.callback
            cause = try mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "drop")); nothing catch error; error end
            @test cause isa ShenScopeError && cause.code == :mcp_outcome_uncertain
            @test timedwait(() -> client.state == :ready && client.generation > generation, 4) == :ok
            @test mcp_request!(client, "ping") == Dict()
            calls = [parsejson(line)["method"] for line in readlines(log)]
            @test count(==("tools/call"), calls) == 3
            @test "notifications/cancelled" in calls
            mcp_catalog(client, :tools)
            old_callback(Dict("jsonrpc" => "2.0", "method" => "notifications/tools/list_changed", "params" => Dict()))
            @test !client.catalogs[:tools].dirty
            slow = @async try mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "slow")) catch error; error end
            @test timedwait(() -> !isempty(client.pending), 2) == :ok
            id = first(keys(client.pending))
            old_callback(Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict("content" => [])))
            @test !istaskdone(slow)
            @test fetch(slow).code == :mcp_outcome_uncertain
        finally
            mcp_disconnect!(client)
        end
        @test isempty(client.pending)
        @test isempty(client.server_requests)
    end
end

@testset "MCP flapping connection exhausts one bounded outage" begin
    mktempdir() do root
        log = joinpath(root, "flaps.jsonl")
        client = mcp_fixture_client(mcp_fixture_context(root); mode = "flap", log, options = Dict("reconnect_attempts" => 2))
        try
            mcp_connect!(client)
            @test timedwait(() -> client.state == :failed && client.reconnect_task !== nothing && istaskdone(client.reconnect_task), 5) == :ok
            calls = [parsejson(line) for line in readlines(log)]
            @test count(item -> item["method"] == "initialize", calls) == 3
            @test client.consecutive_failures == 3
            @test client.state == :failed
        finally
            mcp_disconnect!(client)
        end
    end
end

@testset "MCP parent cancellation closes its owned process without cancelling peers" begin
    mktempdir() do root
        owner = mcp_fixture_context(root)
        peer = mcp_fixture_context(root)
        client = mcp_fixture_client(owner)
        other = mcp_fixture_client(peer)
        try
            mcp_connect!(client)
            mcp_connect!(other)
            process = client.transport.process
            cancel!(owner.cancellation)
            @test timedwait(() -> client.state == :stopped && client.transport === nothing, 3) == :ok
            @test process_exited(process)
            @test other.state == :ready
            @test mcp_request!(other, "ping") == Dict()
        finally
            mcp_disconnect!(client)
            mcp_disconnect!(other)
        end
    end
end
