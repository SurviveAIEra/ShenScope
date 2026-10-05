function language_request!(client::LanguageClient, method::String, params::AbstractDict,
        ctx::RuntimeContext; timeout=client.spec.timeout)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05 <= timeout <= 120 ||
        throw(ShenScopeError(:language_config, "Invalid language request timeout"))
    language_client_access(client, ctx)
    request = lock(client.mutex) do
        client.state in (:connecting, :ready, :stopping) ||
            throw(ShenScopeError(:language_state, "Language server is unavailable"))
        length(client.pending) < client.limits.maximum_pending ||
            throw(ShenScopeError(:capacity, "Language server request capacity reached"))
        client.sequence < typemax(Int)-1 || throw(ShenScopeError(:capacity, "Language request sequence exhausted"))
        client.sequence += 1
        id = string(client.generation) * ":" * string(client.sequence)
        value = LanguagePendingRequest(id, method, client.generation, ctx, Channel{Any}(1), time())
        client.pending[id] = value
        value
    end
    deadline = time() + Float64(timeout)
    sent = false
    try
        language_send!(client, Dict("jsonrpc" => "2.0", "id" => request.id,
            "method" => method, "params" => params), ctx; timeout)
        sent = true
        while !isready(request.result)
            workspace_source_checkpoint(ctx)
            language_client_access(client, ctx)
            time() < deadline || throw(ShenScopeError(:language_timeout, "Language server request timed out; it was not replayed"))
            sleep(0.01)
        end
        value = take!(request.result)
        value isa Exception && throw(value)
        value isa LanguageResponseError &&
            throw(ShenScopeError(:language_remote, "Language server rejected request with code " * string(value.code)))
        language_client_access(client, ctx)
        bounded_canonical_json(value; maximum=client.limits.maximum_message_bytes, max_depth=64, max_nodes=100_000)
        deepcopy(value)
    catch cause
        if sent && cause isa ShenScopeError && cause.code in (:cancelled, :language_timeout)
            # Cancel with an independent token; the cancelled request's token
            # cannot send its own cancellation notification.
            cleanup = child_context(client.context)
            try
                language_notify!(client, "\$/cancelRequest", Dict("id" => request.id), cleanup)
            catch
                nothing
            end
        end
        rethrow()
    finally
        lock(client.mutex) do
            get(client.pending, request.id, nothing) === request && delete!(client.pending, request.id)
        end
    end
end

function language_receive!(client::LanguageClient, generation::Int, message::AbstractDict)
    if haskey(message, "method")
        haskey(message, "id") ? language_server_request!(client, generation, message) :
            language_notification!(client, generation, message)
        return
    end
    request = lock(client.mutex) do
        generation == client.generation && client.state in (:connecting, :ready, :stopping) || return nothing
        id = message["id"]
        id isa String || return nothing
        current = get(client.pending, id, nothing)
        current === nothing && return nothing
        current.generation == generation || return nothing
        delete!(client.pending, id)
        current
    end
    request === nothing && return
    value = haskey(message, "error") ? LanguageResponseError(Int(message["error"]["code"])) : deepcopy(message["result"])
    isready(request.result) || put!(request.result, value)
    nothing
end

function language_server_request!(client::LanguageClient, generation::Int, message::AbstractDict)
    key = canonical(message["id"])
    accepted = lock(client.mutex) do
        generation == client.generation && client.state in (:connecting, :ready) || return false
        !(key in client.inbound_requests) && length(client.inbound_requests) < client.limits.maximum_inbound_requests ||
            throw(ShenScopeError(:language_protocol, "Duplicate or excessive server requests"))
        push!(client.inbound_requests, key)
        true
    end
    accepted || return
    @async begin
        context = child_context(client.context)
        response = Dict{String,Any}("jsonrpc" => "2.0", "id" => message["id"])
        try
            language_client_access(client, context)
            method = message["method"]
            params = get(message, "params", Dict())
            if method == "workspace/configuration"
                response["result"] = language_configuration_response(client, params)
            elseif method == "workspace/workspaceFolders"
                authorize!(context, :read, "language", context.root; reason="Share the owning workspace folder")
                response["result"] = [Dict("uri" => mcp_file_uri(context.root), "name" => basename(context.root))]
            elseif method == "workspace/applyEdit"
                response["result"] = Dict("applied" => false,
                    "failureReason" => "Workspace changes require an explicit reviewed Core edit proposal")
            elseif method == "window/workDoneProgress/create"
                language_fields(params, ["token"], String[], "language progress creation")
                token = language_progress_token(params["token"])
                lock(client.mutex) do
                    length(client.progress) < client.limits.maximum_progress_tokens ||
                        throw(ShenScopeError(:capacity, "Language progress capacity reached"))
                    client.progress[token] = Dict("kind" => "created")
                end
                response["result"] = nothing
            else
                response["error"] = Dict("code" => -32601, "message" => "Client method is not supported")
            end
        catch
            response["error"] = Dict("code" => -32603, "message" => "Client request could not be completed")
        end
        try
            language_send!(client, response, context; timeout=min(5.0, client.spec.timeout))
        catch
            language_connection_failed!(client, generation, :language_transport)
        finally
            lock(client.mutex) do
                delete!(client.inbound_requests, key)
            end
        end
    end
    nothing
end

function language_progress_token(value)
    value isa Integer && !(value isa Bool) && return "number:" * string(value)
    "string:" * language_text(value, "language progress token", 128)
end

function language_notification!(client::LanguageClient, generation::Int, message::AbstractDict)
    active = lock(client.mutex) do
        generation == client.generation && client.state in (:connecting, :ready)
    end
    active || return
    method = message["method"]
    params = get(message, "params", Dict())
    if method == "textDocument/publishDiagnostics"
        receive_language_diagnostics!(client, params)
    elseif method == "\$/progress"
        language_fields(params, ["token", "value"], String[], "language progress update")
        token = language_progress_token(params["token"])
        value = params["value"]
        value isa AbstractDict || return
        kind = get(value, "kind", nothing)
        kind in ("begin", "report", "end") || return
        report = Dict{String,Any}("kind" => kind)
        haskey(value, "title") && (report["title"] = cliptext(language_text(value["title"], "progress title", 4096), 256))
        haskey(value, "percentage") && (report["percentage"] = language_integer(value["percentage"], "progress percentage", 0, 100))
        lock(client.mutex) do
            haskey(client.progress, token) || return
            if kind == "end"
                delete!(client.progress, token)
            else
                client.progress[token] = report
            end
        end
    end
    # Arbitrary log/showMessage payloads and unsupported notifications are
    # deliberately not retained as project evidence or UI HTML.
    nothing
end
