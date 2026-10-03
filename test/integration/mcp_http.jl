using HTTP, Sockets

function with_mcp_http(f::Function, handler::Function; stream = false)
    listener = listen(ip"127.0.0.1", 0)
    port = getsockname(listener)[2]
    server = HTTP.serve!(handler, listener; verbose = false, stream)
    try
        f("http://127.0.0.1:" * string(port) * "/mcp")
    finally
        close(server)
    end
end

function mcp_http_initialization(request)
    Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict("protocolVersion" => ShenScope.MCP_DEFAULT_VERSION,
        "serverInfo" => Dict("name" => "http-fixture", "version" => "1"), "capabilities" => Dict("tools" => Dict())))
end

function mcp_http_definition()
    Dict("name" => "http/echo", "inputSchema" => Dict("type" => "object", "properties" => Dict("text" => Dict("type" => "string")),
        "required" => ["text"], "additionalProperties" => false))
end

@testset "Actual Streamable HTTP JSON, SSE and session ownership" begin
    mktempdir() do root
        captured = Any[]
        deletes = Ref(0)
        handler = req -> begin
            push!(captured, (req.method, HTTP.header(req, "Mcp-Session-Id", ""), HTTP.header(req, "MCP-Protocol-Version", ""), HTTP.header(req, "Authorization", "")))
            req.method == "GET" && return HTTP.Response(405)
            req.method == "DELETE" && (deletes[] += 1; return HTTP.Response(204))
            request = parsejson(String(req.body))
            !haskey(request, "id") && return HTTP.Response(202)
            method = request["method"]
            if method == "initialize"
                return HTTP.Response(200, ["Content-Type" => "application/json", "Mcp-Session-Id" => "fixture-session"], canonical(mcp_http_initialization(request)))
            elseif method == "tools/list"
                result = Dict("tools" => [mcp_http_definition()])
                return HTTP.Response(200, ["Content-Type" => "application/json"], canonical(Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => result)))
            elseif method == "tools/call"
                result = Dict("content" => [Dict("type" => "text", "text" => request["params"]["arguments"]["text"])], "structuredContent" => Dict("answer" => 1))
                wire = ": keepalive\n\ndata: " * canonical(Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => result)) * "\n\n"
                return HTTP.Response(200, ["Content-Type" => "text/event-stream; charset=utf-8"], wire)
            end
            HTTP.Response(500)
        end
        with_mcp_http(handler) do endpoint
            ctx = mcp_fixture_context(root)
            spec = MCPServerSpec("http", Dict("transport" => "http", "endpoint" => endpoint,
                "header_env" => [Dict("name" => "Authorization", "env" => "FIXTURE_HTTP_KEY")]))
            client = MCPClient(spec, ctx; credential_lookup = key -> "fixture-header-value")
            try
                @test mcp_connect!(client)["state"] == "ready"
                @test length(mcp_catalog(client, :tools)) == 1
                @test mcp_call_tool!(client, "http/echo", Dict("text" => "HTTP 中文"))["content"][1]["text"] == "HTTP 中文"
                @test client.transport.session_id == "fixture-session"
                sleep(0.1)
                @test !client.transport.listener_supported
                @test all(item -> item[4] == "fixture-header-value", captured)
                @test all(item -> item[2] == "fixture-session" && item[3] == ShenScope.MCP_DEFAULT_VERSION, captured[2:end])
                @test !occursin("fixture-header-value", canonical(mcp_status(client)))
            finally
                mcp_disconnect!(client)
            end
            @test deletes[] == 1
            @test isempty(client.pending)
        end
    end
end

@testset "HTTP MCP does not replay failed POST or follow redirects" begin
    mktempdir() do root
        for status in (401, 403, 404, 429, 500, 302)
            posted = Ref(0)
            with_mcp_http(req -> begin
                req.method == "GET" && return HTTP.Response(405)
                req.method == "DELETE" && return HTTP.Response(204)
                posted[] += 1
                request = parsejson(String(req.body))
                request["method"] == "initialize" && return HTTP.Response(200, ["Content-Type" => "application/json"], canonical(mcp_http_initialization(request)))
                !haskey(request, "id") && return HTTP.Response(202)
                request["method"] == "tools/list" && return HTTP.Response(200, ["Content-Type" => "application/json"], canonical(Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict("tools" => [mcp_http_definition()]))))
                HTTP.Response(status, ["Location" => "/mcp"], "untrusted remote error")
            end) do endpoint
                client = MCPClient(MCPServerSpec("http", Dict("transport" => "http", "endpoint" => endpoint, "reconnect_attempts" => 0)), mcp_fixture_context(root))
                try
                    mcp_connect!(client)
                    mcp_catalog(client, :tools)
                    before = posted[]
                    cause = try mcp_call_tool!(client, "http/echo", Dict("text" => "test")); nothing catch error; error end
                    @test cause isa ShenScopeError
                    @test cause.code == :mcp_outcome_uncertain
                    @test posted[] == before + 1
                    @test !occursin("untrusted remote error", sprint(showerror, cause))
                finally
                    mcp_disconnect!(client)
                end
            end
        end
    end
end

@testset "SSE HTTP response ends a request while the server keeps the stream open" begin
    mktempdir() do root
        hanging = Ref(false)
        handler = stream -> begin
            req = stream.message
            bytes = read(stream)
            if req.method in ("GET", "DELETE")
                HTTP.setstatus(stream, req.method == "GET" ? 405 : 204)
                HTTP.startwrite(stream)
                return
            end
            request = parsejson(String(bytes))
            if !haskey(request, "id")
                HTTP.setstatus(stream, 202)
                HTTP.startwrite(stream)
                return
            end
            HTTP.setstatus(stream, 200)
            HTTP.setheader(stream, "Content-Type" => "text/event-stream")
            HTTP.startwrite(stream)
            result = request["method"] == "initialize" ? mcp_http_initialization(request) :
                Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict())
            write(stream, "data: " * canonical(result) * "\n\n")
            flush(stream)
            if request["method"] == "ping"
                hanging[] = true
                sleep(0.7)
            end
        end
        with_mcp_http(handler; stream = true) do endpoint
            client = MCPClient(MCPServerSpec("http", Dict("transport" => "http", "endpoint" => endpoint, "timeout" => 0.4)), mcp_fixture_context(root))
            try
                mcp_connect!(client)
                started = time()
                @test mcp_request!(client, "ping") == Dict()
                @test time() - started < 0.4
                @test hanging[]
            finally
                mcp_disconnect!(client)
            end
        end
    end
end

@testset "Actual HTTP GET notification resumption keeps the same session" begin
    mktempdir() do root
        resumed = String[]
        release = Ref(false)
        handler = stream -> begin
            req = stream.message
            bytes = read(stream)
            if req.method == "GET"
                push!(resumed, HTTP.header(req, "Last-Event-ID", ""))
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type" => "text/event-stream")
                HTTP.startwrite(stream)
                if length(resumed) == 1
                    write(stream, "id: priming-event\n\ndata: " * canonical(Dict("jsonrpc" => "2.0", "method" => "notifications/tools/list_changed", "params" => Dict())) * "\n\n")
                    flush(stream)
                else
                    write(stream, ": active notification stream\n\n")
                    flush(stream)
                    deadline = time() + 3
                    while !release[] && time() < deadline; sleep(0.025); end
                end
                return
            elseif req.method == "DELETE"
                HTTP.setstatus(stream, 204)
                HTTP.startwrite(stream)
                return
            end
            request = parsejson(String(bytes))
            if !haskey(request, "id")
                HTTP.setstatus(stream, 202)
                HTTP.startwrite(stream)
                return
            end
            HTTP.setstatus(stream, 200)
            HTTP.setheader(stream, "Content-Type" => "application/json")
            HTTP.setheader(stream, "Mcp-Session-Id" => "resumable-session")
            HTTP.startwrite(stream)
            result = request["method"] == "initialize" ? mcp_http_initialization(request) :
                Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict())
            write(stream, canonical(result))
        end
        with_mcp_http(handler; stream = true) do endpoint
            client = MCPClient(MCPServerSpec("http", Dict("transport" => "http", "endpoint" => endpoint, "reconnect_delay" => 0.01,
                "reconnect_attempts" => 1)), mcp_fixture_context(root))
            try
                mcp_connect!(client)
                @test timedwait(() -> length(resumed) >= 2, 2) == :ok
                @test resumed[1:2] == ["", "priming-event"]
                @test client.generation == 1
                @test client.state == :ready
                @test client.transport.session_id == "resumable-session"
                @test any(item -> item["method"] == "notifications/tools/list_changed", client.notifications)
                @test mcp_request!(client, "ping") == Dict()
            finally
                release[] = true
                mcp_disconnect!(client)
            end
        end
    end
end

