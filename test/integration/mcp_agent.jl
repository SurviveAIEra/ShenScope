@testset "Agent advertises discovered MCP tools on the next request" begin
    mktempdir() do root
        events = AgentEvent[]
        ctx = mcp_fixture_context(root; sink = event -> push!(events, event))
        fixture = abspath(joinpath(@__DIR__, "..", "fixtures", "mcp_server.py"))
        config = Dict("mcp" => Dict("servers" => Dict("fixture" => Dict("argv" => ["python3", fixture]))))
        tools = core_tools(; config)
        alias = mcp_tool_alias("fixture", "echo/input")
        provider = MockProvider(Any[
            function (request)
                @test !any(tool -> tool["name"] == alias, request.tools)
                response(; calls = [ToolCall("connect", "mcp", Dict("action" => "connect", "server" => "fixture"))])
            end,
            function (request)
                declaration = only(tool for tool in request.tools if tool["name"] == alias)
                @test declaration["parameters"]["type"] == "object"
                @test haskey(declaration["parameters"], "\$defs")
                response(; calls = [ToolCall("remote", alias, Dict("value" => "共享 Core MCP"))])
            end,
            function (request)
                output = parsejson(last(request.messages).text)
                @test output["ok"]
                @test output["value"]["structuredContent"]["echo"] == "共享 Core MCP"
                response("Done")
            end])
        try
            @test run_agent!(provider, "Use the configured fixture", ctx; tools) == "Done"
            @test length(provider.requests) == 3
            @test budget_status(ctx.budget)["steps"] == 3
            control = only(tool for tool in tools if tool isa MCPControlTool)
            @test mcp_servers(control.manager, ctx)[1]["state"] == "ready"
            executor = WorkExecutor(; tools = [control])
            @test_throws ShenScopeError ShenScope.execute_worker_tool(executor, "mcp", Dict("action" => "call",
                "server" => "fixture", "name" => "echo/input", "arguments" => Dict("value" => 1, "mode" => "error")), ctx)
            completed = [event for event in events if event.kind == :tool_completed && get(event.payload, "worker", false)]
            @test length(completed) == 1
            @test completed[1].payload["value"]["isError"]
        finally
            for tool in tools; tool isa MCPControlTool && cleanup_mcp!(tool.manager); end
        end
    end
end

@testset "MCP CLI executes the same permissioned Core and closes its process" begin
    mktempdir() do root
        config = deepcopy(ShenScope.DEFAULT_CONFIG)
        fixture = abspath(joinpath(@__DIR__, "..", "fixtures", "mcp_server.py"))
        log = joinpath(root, "methods.jsonl")
        config["mcp"]["servers"]["fixture"] = Dict("argv" => ["python3", fixture, "normal", log])
        path = joinpath(root, "config.toml")
        save_config!(config; path)
        arguments = joinpath(root, "args.json")
        write(arguments, canonical(Dict("value" => "CLI 中文")))
        @test ShenScope.main(["mcp", "servers", "--root", root, "--config", path]) == 0
        @test ShenScope.main(["mcp", "call", "fixture", "echo/input", "args.json", "--root", root, "--config", path,
            "--allow-mcp", "--allow-process"]) == 0
        @test ShenScope.main(["mcp", "call", "fixture", "echo/input", "args.json", "--root", root, "--config", path]) == 1
        calls = parsejson.(readlines(log))
        @test count(item -> item["method"] == "tools/call", calls) == 1
        pid = first(calls)["pid"]
        @test ccall(:kill, Cint, (Cint, Cint), pid, 0) == -1
        @test Base.Libc.errno() == 3
    end
end
