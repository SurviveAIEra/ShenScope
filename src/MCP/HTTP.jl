mutable struct MCPHTTPTransport <: AbstractMCPTransport
    endpoint::String
    headers::Vector{Pair{String,String}}
    session_id::String
    protocol_version::String
    last_event_id::String
    maximum::Int
    generation::Int
    callback::Function
    failed::Function
    streams::Set{Any}
    listener::Union{Nothing,Task}
    closed::Bool
    listener_supported::Bool
    reconnect_attempts::Int
    reconnect_delay::Float64
    stability_seconds::Float64
    mutex::ReentrantLock
end

function mcp_http_transport(spec::MCPServerSpec, ctx::RuntimeContext, generation::Int,
        callback::Function, failed::Function; credential_lookup = key -> get(ENV, key, ""))
    host = String(HTTP.URI(spec.endpoint).host)
    authorize!(ctx, :network, "mcp.http", host; reason = "Connect to the configured MCP endpoint")
    headers = Pair{String,String}["Accept" => "application/json, text/event-stream", "Content-Type" => "application/json"]
    for (name, source) in spec.header_env
        value = credential_lookup(source)
        value isa AbstractString && !isempty(value) && ncodeunits(value) <= 16384 &&
            !any(character -> character in ('\0', '\r', '\n'), value) ||
            throw(ShenScopeError(:mcp_credentials, "Configured MCP header value is missing or invalid: " * source))
        push!(headers, name => value)
    end
    MCPHTTPTransport(spec.endpoint, headers, "", "", "", spec.max_message_bytes, generation,
        callback, failed, Set{Any}(), nothing, false, true, spec.reconnect_attempts,
        spec.reconnect_delay, spec.stability_seconds, ReentrantLock())
end

function mcp_http_headers(transport::MCPHTTPTransport; resume = false)
    lock(transport.mutex) do
        headers = copy(transport.headers)
        !isempty(transport.session_id) && push!(headers, "Mcp-Session-Id" => transport.session_id)
        !isempty(transport.protocol_version) && push!(headers, "MCP-Protocol-Version" => transport.protocol_version)
        resume && !isempty(transport.last_event_id) && push!(headers, "Last-Event-ID" => transport.last_event_id)
        headers
    end
end

function mcp_http_error(status::Integer)
    code = status in (401, 403) ? :mcp_authentication : status == 404 ? :mcp_session_expired :
        status == 429 ? :mcp_rate_limit : status in (408, 504) ? :mcp_timeout : :mcp_http
    ShenScopeError(code, "MCP endpoint returned HTTP " * string(status), status in (408, 429, 500, 502, 503, 504))
end

function mcp_http_register!(transport::MCPHTTPTransport, stream)
    lock(transport.mutex) do
        transport.closed && throw(ShenScopeError(:mcp_transport, "MCP HTTP transport is closed"))
        length(transport.streams) <= MCP_MAX_PENDING + 2 || throw(ShenScopeError(:mcp_transport, "MCP HTTP stream capacity reached"))
        push!(transport.streams, stream)
    end
end

struct MCPHTTPResponseConsumed <: Exception end

function mcp_http_consume!(transport::MCPHTTPTransport, stream, response; listener = false, response_id = nothing)
    content_type = lowercase(first(split(HTTP.header(response, "Content-Type", ""), ';'; limit = 2)))
    if content_type == "text/event-stream"
        decoder = MCPSSEDecoder(transport.maximum)
        id_callback = id -> begin
            listener || return
            lock(transport.mutex) do; transport.last_event_id = id; end
        end
        callback = message -> begin
            transport.callback(message)
            response_id !== nothing && !haskey(message, "method") && get(message, "id", nothing) == response_id &&
                throw(MCPHTTPResponseConsumed())
        end
        try
            while !eof(stream) && !transport.closed
                feed_mcp_sse!(callback, id_callback, decoder, readavailable(stream))
                yield()
            end
            transport.closed || finish_mcp_sse!(callback, id_callback, decoder)
        catch cause
            cause isa MCPHTTPResponseConsumed || rethrow()
        end
    elseif content_type == "application/json" && !listener
        bytes = UInt8[]
        while !eof(stream) && !transport.closed
            chunk = readavailable(stream)
            length(bytes) + length(chunk) <= transport.maximum || throw(ShenScopeError(:mcp_protocol, "MCP HTTP response exceeds capacity"))
            append!(bytes, chunk)
        end
        transport.closed || transport.callback(mcp_decode(String(bytes); maximum = transport.maximum))
    else
        throw(ShenScopeError(:mcp_protocol, "MCP endpoint returned an unsupported content type"))
    end
    nothing
end

function mcp_transport_send!(transport::MCPHTTPTransport, message::AbstractDict,
        ctx::RuntimeContext; timeout = 30.0)
    text = mcp_encode(message, transport.maximum)
    expect_reply = haskey(message, "method") && haskey(message, "id")
    headers = mcp_http_headers(transport)
    HTTP.open("POST", transport.endpoint, headers; readtimeout = max(1, ceil(Int, timeout)),
            connect_timeout = max(1, ceil(Int, min(timeout, 30))), retry = false, redirect = false, status_exception = false) do stream
        mcp_http_register!(transport, stream)
        deadline = time() + timeout
        watcher = @async begin
            while isopen(stream) && !transport.closed && !iscancelled(ctx.cancellation) && time() < deadline
                sleep(0.025)
            end
            (transport.closed || iscancelled(ctx.cancellation) || time() >= deadline) && try close(stream) catch end
        end
        try
            write(stream, text)
            HTTP.closewrite(stream)
            response = HTTP.startread(stream)
            200 <= response.status < 300 || throw(mcp_http_error(response.status))
            session = HTTP.header(response, "Mcp-Session-Id", "")
            if !isempty(session)
                ncodeunits(session) <= 256 && all(character -> '!' <= character <= '~', session) ||
                    throw(ShenScopeError(:mcp_protocol, "Invalid MCP HTTP session ID"))
                lock(transport.mutex) do
                    isempty(transport.session_id) || transport.session_id == session ||
                        throw(ShenScopeError(:mcp_protocol, "MCP HTTP session ID changed within a connection"))
                    transport.session_id = session
                end
            end
            if response.status == 202 || response.status == 204
                expect_reply && throw(ShenScopeError(:mcp_protocol, "MCP request was accepted without a response stream"))
            else
                mcp_http_consume!(transport, stream, response; response_id = expect_reply ? message["id"] : nothing)
            end
            check_cancelled(ctx.cancellation)
            time() < deadline || throw(ShenScopeError(:mcp_timeout, "MCP HTTP request timed out"))
        finally
            try close(stream) catch end
            lock(transport.mutex) do; delete!(transport.streams, stream); end
            wait(watcher)
        end
    end
    nothing
end

function mcp_transport_terminate!(transport::MCPHTTPTransport, ctx::RuntimeContext)
    isempty(transport.session_id) && return
    authorize!(ctx, :network, "mcp.http", String(HTTP.URI(transport.endpoint).host); reason = "Terminate the owned MCP HTTP session")
    HTTP.open("DELETE", transport.endpoint, mcp_http_headers(transport); readtimeout = 2,
            connect_timeout = 2, retry = false, redirect = false, status_exception = false) do stream
        watcher = @async begin
            deadline = time() + 2.0
            while isopen(stream) && time() < deadline && !iscancelled(ctx.cancellation); sleep(0.025); end
            try close(stream) catch end
        end
        try
            HTTP.closewrite(stream)
            HTTP.startread(stream)
            # Session deletion is best effort. Never expose or retain its body.
        finally
            try close(stream) catch end
            wait(watcher)
        end
    end
    nothing
end

mcp_transport_terminate!(::MCPStdioTransport, ::RuntimeContext) = nothing

function mcp_http_listen!(transport::MCPHTTPTransport, ctx::RuntimeContext)
    transport.listener = @async begin
        failures = 0
        while !transport.closed && !iscancelled(ctx.cancellation)
            started = time()
            try
                HTTP.open("GET", transport.endpoint, mcp_http_headers(transport; resume = true);
                        readtimeout = 0, connect_timeout = 10, retry = false, redirect = false, status_exception = false) do stream
                    mcp_http_register!(transport, stream)
                    watcher = @async begin
                        while isopen(stream) && !transport.closed && !iscancelled(ctx.cancellation); sleep(0.025); end
                        (transport.closed || iscancelled(ctx.cancellation)) && try close(stream) catch end
                    end
                    try
                        response = HTTP.startread(stream)
                        if response.status in (405, 501)
                            transport.listener_supported = false
                            return
                        end
                        200 <= response.status < 300 || throw(mcp_http_error(response.status))
                        mcp_http_consume!(transport, stream, response; listener = true)
                    finally
                        try close(stream) catch end
                        lock(transport.mutex) do; delete!(transport.streams, stream); end
                        wait(watcher)
                    end
                end
                transport.listener_supported || break
            catch cause
                transport.closed && break
                if cause isa ShenScopeError && cause.code in (:mcp_authentication, :mcp_session_expired, :mcp_protocol)
                    transport.failed(cause.code)
                    break
                end
            end
            time() - started >= transport.stability_seconds && (failures = 0)
            failures += 1
            if failures > transport.reconnect_attempts
                transport.failed(:mcp_listener_lost)
                break
            end
            try
                cancellable_wait(ctx.cancellation, min(30.0, transport.reconnect_delay * 2.0^(failures - 1)))
            catch
                break
            end
        end
    end
    transport.listener
end

function mcp_transport_close!(transport::MCPHTTPTransport)
    streams = lock(transport.mutex) do
        transport.closed = true
        collect(transport.streams)
    end
    for stream in streams; try close(stream) catch end; end
    listener = transport.listener
    listener !== nothing && listener !== current_task() && try wait(listener) catch end
    empty!(transport.headers)
    nothing
end
