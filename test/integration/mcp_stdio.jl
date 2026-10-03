function mcp_fixture_context(root; sink = event -> nothing)
    RuntimeContext(root; state_dir = joinpath(root, "state"), sink,
        permissions = PermissionPolicy(; rules = Dict(:mcp => Allow, :process => Allow, :network => Allow, :read => Allow)))
end

function mcp_fixture_client(ctx; mode = "normal", log = "", options = Dict())
    script = abspath(joinpath(@__DIR__, "..", "fixtures", "mcp_server.py"))
    # Functional fixtures allow first-call Julia compilation; deadline tests override this.
    config = merge(Dict{String,Any}("argv" => ["python3", script, mode, log], "timeout" => 10.0,
        "reconnect_delay" => 0.02, "stability_seconds" => 1.0), options)
    ShenScope.MCPClient(ShenScope.MCPServerSpec("fixture", config), ctx)
end

@testset "Actual MCP stdio lifecycle and discovery" begin
    mktempdir() do root
        events = AgentEvent[]
        ctx = mcp_fixture_context(root; sink = event -> push!(events, event))
        client = mcp_fixture_client(ctx)
        try
            @test ShenScope.mcp_connect!(client)["state"] == "ready"
            @test client.protocol_version == ShenScope.MCP_DEFAULT_VERSION
            @test ShenScope.mcp_test_connection!(client)["ok"]
            @test length(ShenScope.mcp_catalog(client, :tools)) == 2
            @test !client.catalogs[:tools].dirty
            @test length(ShenScope.mcp_catalog(client, :resources)) == 1
            @test length(ShenScope.mcp_catalog(client, :templates)) == 1
            @test ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => "中文"))["structuredContent"]["echo"] == "中文"
            @test_throws ShenScopeError ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => -1))
            @test_throws ShenScopeError ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => true))
            @test ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "error"))["isError"]
            @test_throws ShenScopeError ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "bad_output"))
            @test_throws ShenScope.MCPRemoteError ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "rpc_error"))
            @test mcp_status(client)["last_error"]["code"] == "mcp_remote"
            @test !occursin("FAKE_SECRET", canonical(mcp_status(client)))
            @test ShenScope.mcp_read_resource!(client, "fixture://sample")["contents"][1]["text"] == "资源内容"
            @test ShenScope.mcp_get_prompt!(client, "review", Dict("file" => "app.jl"))["messages"][1]["content"]["text"] == "Review app.jl"
            @test_throws ShenScopeError ShenScope.mcp_get_prompt!(client, "review", Dict())
            @test_throws ShenScopeError ShenScope.mcp_get_prompt!(client, "review", Dict("file" => 1))
            @test ShenScope.mcp_complete!(client, Dict("type" => "ref/prompt", "name" => "review"), Dict("name" => "file", "value" => "a"))["completion"]["values"] == ["alpha", "beta"]
            roots = ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "roots"))["structuredContent"]["echo"]
            @test roots["roots"][1]["uri"] == ShenScope.mcp_file_uri(root)
            unsupported = ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "unsupported"))["structuredContent"]["echo"]
            @test unsupported["code"] == -32601
            ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "progress"))
            @test [event.payload["progress"] for event in events if event.kind == :mcp_progress] == [1, 2]
            ShenScope.mcp_call_tool!(client, "echo/input", Dict("value" => 1, "mode" => "changed"))
            @test client.catalogs[:tools].dirty
            ShenScope.mcp_catalog(client, :tools)
            @test !client.catalogs[:tools].dirty
            ShenScope.mcp_subscribe!(client, "fixture://sample")
            sleep(0.1)
            @test get(client.resource_versions, "fixture://sample", 0) == 1
            @test any(event -> event.kind == :mcp_resource_updated, events)
            ShenScope.mcp_subscribe!(client, "fixture://sample"; unsubscribe = true)
            @test isempty(client.subscriptions)
            @test isempty(client.pending)
            @test length(mcp_status(client)["notifications"]) >= 3
            previous = client.generation
            @test mcp_reconnect!(client)["generation"] > previous
            @test mcp_status(client)["last_error"] === nothing
        finally
            ShenScope.mcp_disconnect!(client)
        end
        @test client.state == :stopped
        @test client.transport === nothing
    end
end
