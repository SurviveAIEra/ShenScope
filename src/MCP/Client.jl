function mcp_scope(client::MCPClient, ctx::RuntimeContext)
    client.context.root == ctx.root && client.context.session_id == ctx.session_id ||
        throw(ShenScopeError(:mcp_scope, "MCP connection belongs to another workspace or session"))
    check_cancelled(ctx.cancellation)
    nothing
end

function mcp_request_permission!(client::MCPClient, method::String, params::AbstractDict, ctx::RuntimeContext)
    target = mcp_permission_target(client.spec)
    if method == "tools/call"
        target *= ":tool:" * mcp_string(get(params, "name", nothing), "tool name"; maximum = 256) * ":" * digest(canonical(get(params, "arguments", Dict())))
    end
    authorize!(ctx, :mcp, "mcp." * method, target; reason = "Use the configured MCP server: " * client.spec.name)
    if client.spec.transport == :http
        authorize!(ctx, :network, "mcp.http", String(HTTP.URI(client.spec.endpoint).host); reason = "Send an MCP request")
    else
        target = canonical(Dict("argv" => client.spec.argv, "cwd" => workspace_path(ctx.root, client.spec.cwd),
            "environment_sources" => client.spec.environment_env))
        authorize!(ctx, :process, "mcp.process", target; reason = "Use the configured MCP server process")
    end
end

function mcp_notification_send!(client::MCPClient, method::String, params::AbstractDict,
        ctx::RuntimeContext = client.context; timeout = min(5.0, client.spec.timeout), allow_connecting = false)
    transport = lock(client.mutex) do
        client.state == :ready || allow_connecting && client.state == :connecting ||
            throw(ShenScopeError(:mcp_unavailable, "MCP server is not connected"))
        client.transport
    end
    transport === nothing && throw(ShenScopeError(:mcp_unavailable, "MCP server is not connected"))
    mcp_transport_send!(transport, mcp_notification_message(method, params), ctx; timeout)
end

function mcp_cancel_request!(client::MCPClient, pending::MCPPending)
    transport = lock(client.mutex) do
        client.generation == pending.generation && client.state in (:connecting, :ready) ? client.transport : nothing
    end
    transport === nothing && return
    # Use a separate short-lived context: the original request is already cancelled.
    ctx = child_context(client.context)
    try
        mcp_transport_send!(transport, mcp_notification_message("notifications/cancelled",
            Dict("requestId" => pending.id, "reason" => "Client cancelled or timed out")), ctx; timeout = 0.5)
    catch
        nothing
    finally
        cancel!(ctx.cancellation)
    end
    nothing
end

function mcp_request!(client::MCPClient, method::AbstractString, params::AbstractDict = Dict(),
        ctx::RuntimeContext = client.context; timeout = client.spec.timeout, allow_connecting = false,
        permission = true, progress = true)
    mcp_scope(client, ctx)
    name = mcp_string(method, "RPC method"; maximum = 256)
    limit = mcp_number(timeout, "request timeout"; minimum = 0.01)
    mcp_json_value(params; max_bytes = client.spec.max_message_bytes)
    permission && mcp_request_permission!(client, name, params, ctx)
    owned = child_context(ctx)
    pending = MCPPending(string(uuid4()), name, 0, owned, Channel{Any}(1), string(uuid4()), 0.0, false)
    arguments = Dict{String,Any}(deepcopy(params))
    if progress
        metadata = get(arguments, "_meta", Dict())
        metadata isa AbstractDict || throw(ShenScopeError(:mcp_arguments, "MCP request metadata must be an object"))
        arguments["_meta"] = merge(Dict{String,Any}(metadata), Dict("progressToken" => pending.progress_token))
    end
    message = mcp_request_message(pending.id, name, arguments)
    mcp_encode(message, client.spec.max_message_bytes)
    transport = lock(client.mutex) do
        client.state == :ready || allow_connecting && client.state == :connecting ||
            throw(ShenScopeError(:mcp_unavailable, "MCP server is not connected"))
        length(client.pending) < MCP_MAX_PENDING || throw(ShenScopeError(:mcp_capacity, "MCP pending request capacity reached"))
        pending.generation = client.generation
        client.pending[pending.id] = pending
        client.transport
    end
    sender = @async begin
        try
            check_cancelled(owned.cancellation)
            pending.submitted = true
            mcp_transport_send!(transport, message, owned; timeout = limit)
            nothing
        catch cause
            cause isa ShenScopeError ? cause : ShenScopeError(:mcp_transport, "MCP transport failed")
        end
    end
    deadline = time() + limit
    received = false
    try
        while true
            if isready(pending.result)
                result = take!(pending.result)
                received = !(result isa Exception) || result isa MCPRemoteError
                result isa Exception && throw(result)
                return result
            end
            check_cancelled(ctx.cancellation)
            time() < deadline || throw(ShenScopeError(:mcp_timeout, "MCP request timed out"))
            if istaskdone(sender)
                cause = fetch(sender)
                if cause isa Exception
                    mcp_connection_failed!(client, pending.generation, cause isa ShenScopeError ? cause.code : :mcp_transport)
                    throw(cause)
                end
            end
            sleep(0.01)
        end
    catch cause
        uncertain = pending.submitted && name == "tools/call" &&
            !(cause isa MCPRemoteError) && !received
        mcp_record_error!(client, name, uncertain ? :mcp_outcome_uncertain :
            cause isa ShenScopeError ? cause.code : cause isa MCPRemoteError ? :mcp_remote : :mcp_transport;
            generation = pending.generation)
        uncertain && throw(ShenScopeError(:mcp_outcome_uncertain, "MCP tool was submitted without a confirmed result; it was not replayed"))
        rethrow()
    finally
        removed = lock(client.mutex) do
            get(client.pending, pending.id, nothing) === pending || return false
            delete!(client.pending, pending.id)
            true
        end
        !received && removed && pending.submitted && mcp_cancel_request!(client, pending)
        cancel!(owned.cancellation, "MCP request ended")
        # HTTP streams and blocked stdio writes observe the owned cancellation.
        try wait(sender) catch end
    end
end

function mcp_capabilities(value)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP capabilities must be an object"))
    for (name, capability) in value
        capability isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP capability must be an object"))
        if name in ("tools", "prompts", "resources")
            for field in ("listChanged", "subscribe")
                haskey(capability, field) && !(capability[field] isa Bool) &&
                    throw(ShenScopeError(:mcp_protocol, "MCP capability flag must be boolean"))
            end
        end
    end
    Dict{String,Any}(deepcopy(value))
end

function mcp_close_barrier!(client::MCPClient, transport, requests)
    for request in requests; cancel!(request.context.cancellation, "MCP connection closed"); end
    transport !== nothing && mcp_transport_close!(transport)
    deadline = time() + 2.0
    for request in requests
        task = request.task
        (task === nothing || task === current_task() || istaskdone(task)) && continue
        while !istaskdone(task) && time() < deadline; sleep(0.01); end
        istaskdone(task) || throw(ShenScopeError(:mcp_close, "MCP client callback did not stop; reconnection is blocked"))
        try wait(task) catch end
    end
    nothing
end

function mcp_connect!(client::MCPClient; ctx = client.context, reset_failures = true)
    mcp_scope(client, ctx)
    lock(client.lifecycle_mutex) do
        lock(client.mutex) do
            client.state == :ready && return
        end
        client.state == :ready && return mcp_status(client)
        client.spec.enabled || throw(ShenScopeError(:mcp_disabled, "MCP server is disabled"))
        authorize!(ctx, :mcp, "mcp.connect", mcp_permission_target(client.spec); reason = "Connect MCP server: " * client.spec.name)
        previous, requests = lock(client.mutex) do
            (client.transport, collect(values(client.server_requests)))
        end
        mcp_close_barrier!(client, previous, requests)
        generation = lock(client.mutex) do
            client.transport = nothing
            empty!(client.server_requests)
            empty!(client.subscriptions)
            empty!(client.resource_versions)
            client.generation += 1
            client.stopping = false
            if iscancelled(client.context.cancellation)
                client.context.cancellation = CancellationToken(client.context.cancellation.parent)
            end
            check_cancelled(client.context.cancellation)
            client.state = :connecting
            client.protocol_version = ""
            empty!(client.server_info)
            empty!(client.capabilities)
            client.instructions = ""
            reset_failures && (client.consecutive_failures = 0)
            for catalog in values(client.catalogs)
                catalog.dirty = true
                catalog.revision += 1
            end
            client.generation
        end
        callback = message -> mcp_receive!(client, generation, message)
        failed = reason -> mcp_connection_failed!(client, generation, reason)
        try
            transport = client.spec.transport == :stdio ?
                mcp_stdio_transport(client.spec, ctx, generation, callback, failed; credential_lookup = client.credential_lookup) :
                mcp_http_transport(client.spec, ctx, generation, callback, failed; credential_lookup = client.credential_lookup)
            lock(client.mutex) do; client.transport = transport; end
            result = mcp_request!(client, "initialize", Dict("protocolVersion" => MCP_DEFAULT_VERSION,
                "capabilities" => Dict("roots" => Dict("listChanged" => false)),
                "clientInfo" => Dict("name" => "ShenScope", "version" => string(VERSION))), ctx;
                timeout = client.spec.connect_timeout, allow_connecting = true, permission = false, progress = false)
            result isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP initialization result must be an object"))
            version = get(result, "protocolVersion", nothing)
            version in MCP_SUPPORTED_VERSIONS || throw(ShenScopeError(:mcp_version, "MCP server selected an unsupported protocol version"))
            client.spec.transport == :http && version == "2024-11-05" &&
                throw(ShenScopeError(:mcp_version, "Streamable HTTP requires MCP 2025-03-26 or newer"))
            info = get(result, "serverInfo", nothing)
            info isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP server info must be an object"))
            mcp_string(get(info, "name", nothing), "server name"; maximum = 256)
            mcp_string(get(info, "version", nothing), "server version"; maximum = 256)
            capabilities = mcp_capabilities(get(result, "capabilities", nothing))
            instructions = mcp_string(get(result, "instructions", ""), "server instructions"; maximum = 32768, empty = true)
            transport isa MCPHTTPTransport && (transport.protocol_version = version)
            mcp_notification_send!(client, "notifications/initialized", Dict(), ctx; allow_connecting = true)
            lock(client.mutex) do
                client.generation == generation && client.state == :connecting ||
                    throw(ShenScopeError(:mcp_transport, "MCP connection was lost during initialization"))
                client.protocol_version = version
                client.server_info = Dict{String,Any}(deepcopy(info))
                client.capabilities = capabilities
                client.instructions = instructions
                client.connected_at = time()
                client.last_error = nothing
                client.state = :ready
            end
            transport isa MCPHTTPTransport && mcp_http_listen!(transport, client.context)
            client.lifetime_task = @async begin
                while client.generation == generation && !client.stopping && client.state in (:ready, :backoff, :connecting)
                    if iscancelled(client.context.cancellation)
                        mcp_disconnect!(client; terminate_session = false)
                        return
                    end
                    sleep(0.025)
                end
            end
            emit!(ctx, :mcp_connected, Dict("server" => client.spec.name, "generation" => generation, "protocol_version" => version))
            mcp_status(client)
        catch cause
            mcp_record_error!(client, "connect", cause isa ShenScopeError ? cause.code : :mcp_transport; generation)
            previous, requests = lock(client.mutex) do
                client.state = :failed
                (client.transport, collect(values(client.server_requests)))
            end
            mcp_close_barrier!(client, previous, requests)
            rethrow()
        end
    end
end

function mcp_connection_failed!(client::MCPClient, generation::Int, reason::Symbol)
    snapshot = lock(client.mutex) do
        client.generation == generation && !client.stopping && client.state in (:connecting, :ready) || return nothing
        was_ready = client.state == :ready
        was_ready && time() - client.connected_at >= client.spec.stability_seconds && (client.consecutive_failures = 0)
        client.state = was_ready ? :backoff : :failed
        client.last_error = Dict("code" => String(reason), "operation" => "transport", "generation" => generation, "timestamp" => utcstamp())
        pending = collect(values(client.pending))
        empty!(client.pending)
        for catalog in values(client.catalogs); catalog.dirty = true; catalog.revision += 1; end
        (was_ready, pending, client.transport, collect(values(client.server_requests)))
    end
    snapshot === nothing && return
    for pending in snapshot[2]
        isready(pending.result) || put!(pending.result, ShenScopeError(:mcp_transport, "MCP connection was lost"))
    end
    for request in snapshot[4]; cancel!(request.context.cancellation, "MCP connection lost"); end
    emit!(client.context, :mcp_disconnected, Dict("server" => client.spec.name, "generation" => generation, "reason" => String(reason)))
    if snapshot[1]
        lock(client.mutex) do
            if client.reconnect_task === nothing || istaskdone(client.reconnect_task)
                client.reconnect_task = @async mcp_reconnect_supervisor!(client, generation)
            end
        end
    else
        @async try mcp_close_barrier!(client, snapshot[3], snapshot[4]) catch end
    end
    nothing
end

function mcp_reconnect_supervisor!(client::MCPClient, failed_generation::Int)
    while true
        attempt = lock(client.mutex) do
            client.stopping || iscancelled(client.context.cancellation) || client.state == :ready || begin
                client.consecutive_failures += 1
                if client.consecutive_failures <= client.spec.reconnect_attempts
                    return client.consecutive_failures
                end
                client.state = :failed
            end
            nothing
        end
        attempt === nothing && return
        try
            cancellable_wait(client.context.cancellation, min(30.0, client.spec.reconnect_delay * 2.0^(attempt - 1)))
            mcp_connect!(client; reset_failures = false)
            # Stay responsible until a stable interval. A flapping transport
            # cannot reset the outage limit by succeeding its handshake briefly.
            deadline = time() + client.spec.stability_seconds
            while client.state == :ready && !client.stopping && time() < deadline
                cancellable_wait(client.context.cancellation, min(0.025, max(0.0, deadline - time())))
            end
            client.state == :ready && return
        catch cause
            iscancelled(client.context.cancellation) && return
            cause isa ShenScopeError && cause.code in (:permission, :mcp_credentials, :mcp_version, :mcp_close) && begin
                lock(client.mutex) do; client.state = :failed; end
                return
            end
        end
    end
end

function mcp_disconnect!(client::MCPClient; terminate_session = true)
    snapshot = lock(client.mutex) do
        client.stopping = true
        client.state = :stopped
        pending = collect(values(client.pending))
        empty!(client.pending)
        (client.transport, pending, collect(values(client.server_requests)), client.reconnect_task, client.lifetime_task)
    end
    for pending in snapshot[2]
        isready(pending.result) || put!(pending.result, ShenScopeError(:mcp_closed, "MCP connection was closed"))
    end
    cancel!(client.context.cancellation, "MCP connection stopped")
    lock(client.lifecycle_mutex) do
        if terminate_session && snapshot[1] !== nothing
            ctx = RuntimeContext(client.context.root; session_id = client.context.session_id, state_dir = client.context.state_dir,
                permissions = client.context.permissions, budget = client.context.budget)
            try mcp_transport_terminate!(snapshot[1], ctx) catch end
        end
        mcp_close_barrier!(client, snapshot[1], snapshot[3])
        lock(client.mutex) do
            client.transport = nothing
            empty!(client.server_requests)
            empty!(client.subscriptions)
            for catalog in values(client.catalogs); catalog.dirty = true; catalog.revision += 1; end
        end
    end
    supervisor = snapshot[4]
    supervisor !== nothing && supervisor !== current_task() && try wait(supervisor) catch end
    monitor = snapshot[5]
    monitor !== nothing && monitor !== current_task() && try wait(monitor) catch end
    mcp_status(client)
end

function mcp_reconnect!(client::MCPClient; ctx = client.context)
    mcp_scope(client, ctx)
    mcp_disconnect!(client)
    # Reopen the owned token while retaining cancellation from the session.
    client.context.cancellation = CancellationToken(client.context.cancellation.parent)
    mcp_connect!(client; ctx, reset_failures = true)
end

function mcp_status(client::MCPClient)
    lock(client.mutex) do
        Dict("name" => client.spec.name, "transport" => String(client.spec.transport), "state" => String(client.state),
            "generation" => client.generation, "protocol_version" => client.protocol_version,
            "server_info" => deepcopy(client.server_info), "capabilities" => deepcopy(client.capabilities),
            "pending_requests" => length(client.pending), "server_requests" => length(client.server_requests),
            "last_error" => deepcopy(client.last_error), "notifications" => deepcopy(client.notifications),
            "reconnect_failures" => client.consecutive_failures, "subscriptions" => sort!(collect(client.subscriptions)),
            "catalogs" => Dict(String(kind) => Dict("count" => length(catalog.items), "revision" => catalog.revision,
                "dirty" => catalog.dirty, "generation" => catalog.generation) for (kind, catalog) in client.catalogs))
    end
end

function mcp_record_error!(client::MCPClient, operation::String, code::Symbol; generation = client.generation)
    lock(client.mutex) do
        client.generation == generation || return
        client.last_error = Dict("code" => String(code), "operation" => operation,
            "generation" => generation, "timestamp" => utcstamp())
    end
    nothing
end

function mcp_test_connection!(client::MCPClient, ctx::RuntimeContext = client.context)
    started = time_ns()
    result = mcp_request!(client, "ping", Dict(), ctx; progress = false)
    result isa AbstractDict && isempty(result) || throw(ShenScopeError(:mcp_protocol, "MCP ping must return an empty object"))
    Dict("ok" => true, "latency_ms" => (time_ns() - started) / 1.0e6, "status" => mcp_status(client))
end
