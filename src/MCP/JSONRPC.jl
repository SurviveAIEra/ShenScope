function mcp_decode(raw::AbstractString; maximum = MCP_MAX_MESSAGE_BYTES)
    ncodeunits(raw) <= maximum && isvalid(raw) || throw(ShenScopeError(:mcp_protocol, "MCP message exceeds capacity or contains invalid UTF-8"))
    depth = 0
    quoted = false
    escaped = false
    for byte in codeunits(raw)
        if quoted
            if escaped
                escaped = false
            elseif byte == 0x5c
                escaped = true
            elseif byte == 0x22
                quoted = false
            end
        elseif byte == 0x22
            quoted = true
        elseif byte in (0x7b, 0x5b)
            depth += 1
            depth <= 64 || throw(ShenScopeError(:mcp_protocol, "MCP JSON nesting exceeds capacity"))
        elseif byte in (0x7d, 0x5d)
            depth -= 1
        end
    end
    value = try parsejson(raw) catch; throw(ShenScopeError(:mcp_protocol, "Malformed MCP JSON")); end
    mcp_json_value(value; max_bytes = maximum)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP messages must be JSON objects"))
    get(value, "jsonrpc", nothing) == "2.0" || throw(ShenScopeError(:mcp_protocol, "Unsupported JSON-RPC version"))
    if haskey(value, "method")
        mcp_string(value["method"], "RPC method"; maximum = 256)
        !(haskey(value, "result") || haskey(value, "error")) || throw(ShenScopeError(:mcp_protocol, "MCP request contains response fields"))
        get(value, "params", Dict()) isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP params must be an object"))
        haskey(value, "id") && !mcp_rpc_id(value["id"]) && throw(ShenScopeError(:mcp_protocol, "Invalid MCP request ID"))
    else
        haskey(value, "id") && mcp_rpc_id(value["id"]) || throw(ShenScopeError(:mcp_protocol, "MCP response has no valid request ID"))
        xor(haskey(value, "result"), haskey(value, "error")) || throw(ShenScopeError(:mcp_protocol, "MCP response must contain result or error"))
        if haskey(value, "error")
            error = value["error"]
            error isa AbstractDict && get(error, "code", nothing) isa Integer && !(error["code"] isa Bool) &&
                get(error, "message", nothing) isa AbstractString || throw(ShenScopeError(:mcp_protocol, "Invalid MCP error response"))
        end
    end
    value
end

function mcp_rpc_id(value)
    value isa AbstractString && 1 <= ncodeunits(value) <= 256 && isvalid(value) && return true
    value isa Integer && !(value isa Bool)
end

mcp_request_message(id, method::String, params::AbstractDict) = Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)
mcp_notification_message(method::String, params::AbstractDict) = Dict("jsonrpc" => "2.0", "method" => method, "params" => params)

function mcp_encode(message::AbstractDict, maximum::Int)
    mcp_json_value(message; max_bytes = maximum)
    text = canonical(message)
    ncodeunits(text) <= maximum || throw(ShenScopeError(:mcp_protocol, "Outgoing MCP message exceeds capacity"))
    text
end

function mcp_file_uri(path::String)
    bytes = codeunits(replace(abspath(path), '\\' => '/'))
    encoded = IOBuffer()
    for byte in bytes
        if 0x41 <= byte <= 0x5a || 0x61 <= byte <= 0x7a || 0x30 <= byte <= 0x39 || byte in (0x2d, 0x2e, 0x5f, 0x7e, 0x2f, 0x3a)
            write(encoded, byte)
        else
            write(encoded, '%', uppercase(string(byte; base = 16, pad = 2)))
        end
    end
    value = String(take!(encoded))
    "file://" * (startswith(value, "/") ? value : "/" * value)
end

function mcp_response_value(message::AbstractDict)
    if haskey(message, "error")
        # Remote error text/data can contain server credentials and environment
        # output. Expose a controlled code; protocol content stays separate.
        return MCPRemoteError(Int(message["error"]["code"]), "Remote request rejected", nothing)
    end
    deepcopy(message["result"])
end

function mcp_receive!(client::MCPClient, generation::Int, message::AbstractDict)
    if haskey(message, "method")
        haskey(message, "id") ? mcp_server_request!(client, generation, message) : mcp_notification!(client, generation, message)
        return
    end
    id = message["id"]
    pending = lock(client.mutex) do
        client.generation == generation && !client.stopping || return nothing
        id isa AbstractString || return nothing
        current = get(client.pending, id, nothing)
        current !== nothing && current.generation == generation || return nothing
        delete!(client.pending, id)
        current
    end
    pending === nothing && return
    put!(pending.result, mcp_response_value(message))
end

function mcp_server_request!(client::MCPClient, generation::Int, message::AbstractDict)
    key = string(generation) * ":" * canonical(message["id"])
    task = lock(client.mutex) do
        client.generation == generation && !client.stopping && client.state in (:connecting, :ready) || return nothing
        length(client.server_requests) < MCP_MAX_SERVER_REQUESTS && !haskey(client.server_requests, key) ||
            throw(ShenScopeError(:mcp_protocol, "Too many or duplicate MCP server requests"))
        request = MCPInboundRequest(generation, child_context(client.context), nothing)
        worker = @async with_context(request.context) do
            response = Dict{String,Any}("jsonrpc" => "2.0", "id" => message["id"])
            try
                method = message["method"]
                if method == "ping"
                    response["result"] = Dict()
                elseif method == "roots/list"
                    authorize!(request.context, :read, "mcp.roots", client.context.root; reason = "Share the current workspace root with the MCP server")
                    response["result"] = Dict("roots" => [Dict("uri" => mcp_file_uri(client.context.root), "name" => basename(client.context.root))])
                else
                    response["error"] = Dict("code" => -32601, "message" => "Client method is not supported")
                end
            catch
                response["error"] = Dict("code" => -32603, "message" => "Client request could not be completed")
            end
            try
                transport = lock(client.mutex) do
                    client.generation == generation && !client.stopping && client.state in (:connecting, :ready) ? client.transport : nothing
                end
                transport !== nothing && mcp_transport_send!(transport, response, request.context; timeout = min(5.0, client.spec.timeout))
            catch
                mcp_connection_failed!(client, generation, :transport)
            finally
                lock(client.mutex) do
                    get(client.server_requests, key, nothing) === request && delete!(client.server_requests, key)
                end
            end
        end
        request.task = worker
        client.server_requests[key] = request
        worker
    end
    task
end

function mcp_notification!(client::MCPClient, generation::Int, message::AbstractDict)
    method = message["method"]
    params = get(message, "params", Dict())
    progress = nothing
    resource = nothing
    lock(client.mutex) do
        client.generation == generation && !client.stopping && client.state in (:connecting, :ready) || return
        if method in ("notifications/tools/list_changed", "notifications/resources/list_changed", "notifications/prompts/list_changed")
            kind = method == "notifications/tools/list_changed" ? :tools : method == "notifications/prompts/list_changed" ? :prompts : :resources
            client.catalogs[kind].dirty = true
            client.catalogs[kind].revision += 1
            kind == :resources && (client.catalogs[:templates].dirty = true; client.catalogs[:templates].revision += 1)
        elseif method == "notifications/resources/updated"
            uri = get(params, "uri", nothing)
            if uri isa AbstractString && uri in client.subscriptions
                client.resource_versions[uri] = get(client.resource_versions, uri, 0) + 1
                resource = Dict("server" => client.spec.name, "uri" => uri, "revision" => client.resource_versions[uri])
            end
        elseif method == "notifications/progress"
            token = get(params, "progressToken", nothing)
            for pending in values(client.pending)
                token == pending.progress_token || continue
                amount = get(params, "progress", nothing)
                total = get(params, "total", nothing)
                amount isa Real && !(amount isa Bool) && isfinite(amount) && amount >= pending.progress || break
                total === nothing || total isa Real && !(total isa Bool) && isfinite(total) && total >= amount || break
                pending.progress = Float64(amount)
                progress = (pending.context, Dict("server" => client.spec.name, "request_id" => pending.id,
                    "progress" => amount, "total" => total, "message" => cliptext(string(get(params, "message", "")), 1024)))
                break
            end
        end
        # Do not retain arbitrary server log/content payloads in diagnostics.
        push!(client.notifications, Dict("method" => method, "generation" => generation, "timestamp" => utcstamp()))
        length(client.notifications) > MCP_MAX_NOTIFICATIONS && popfirst!(client.notifications)
    end
    progress !== nothing && emit!(progress[1], :mcp_progress, progress[2])
    resource !== nothing && emit!(client.context, :mcp_resource_updated, resource)
end
