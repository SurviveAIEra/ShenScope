function start_language_client!(client::LanguageClient)
    lock(client.lifecycle_mutex) do
        client.state == :created || throw(ShenScopeError(:language_state, "Language server has already been started"))
        authorize!(client.context, :read, "language", client.context.root; reason="Share this workspace with an explicitly selected language server")
        workspace_source_checkpoint(client.context)
        lock(client.mutex) do
            client.state = :connecting
        end
        try
            transport = language_transport(client)
            lock(client.mutex) do
                if client.state == :failed
                    mcp_transport_close!(transport)
                    throw(ShenScopeError(:language_transport, "Language server exited while starting"))
                end
                client.transport = transport
            end
            root = client.context.root
            result = language_request!(client, "initialize", Dict(
                "processId" => getpid(), "clientInfo" => Dict("name" => "ShenScope", "version" => string(VERSION)),
                "rootUri" => mcp_file_uri(root), "capabilities" => language_client_capabilities(),
                "workspaceFolders" => [Dict("uri" => mcp_file_uri(root), "name" => basename(root))],
                "initializationOptions" => deepcopy(client.spec.initialization_options)), client.context)
            capabilities = language_server_capabilities(result)
            language_notify!(client, "initialized", Dict{String,Any}(), client.context)
            if !isempty(client.spec.settings)
                language_notify!(client, "workspace/didChangeConfiguration", Dict("settings" => client.spec.settings), client.context)
            end
            lock(client.mutex) do
                client.state == :connecting || throw(ShenScopeError(:language_transport, "Language server disconnected during initialization"))
                client.capabilities = capabilities
                client.state = :ready
            end
            client.monitor = @async begin
                while lock(client.mutex) do; client.state == :ready; end
                    sleep(0.1)
                    try
                        language_client_access(client, client.context)
                    catch
                        language_connection_failed!(client, client.generation, :permission_revoked)
                        break
                    end
                end
            end
            language_client_status(client, client.context)
        catch cause
            language_connection_failed!(client, client.generation,
                cause isa ShenScopeError ? cause.code : :language_start)
            rethrow()
        end
    end
end

function stop_language_client!(client::LanguageClient; graceful=true)
    lock(client.lifecycle_mutex) do
        prior = lock(client.mutex) do
            current = client.state
            current == :closed && return current
            client.state = :stopping
            current
        end
        prior == :closed && return nothing
        if graceful && prior == :ready && !iscancelled(client.context.cancellation)
            try
                language_request!(client, "shutdown", Dict{String,Any}(), client.context; timeout=min(2.0, client.spec.timeout))
                language_notify!(client, "exit", Dict{String,Any}(), client.context)
            catch
                nothing
            end
        end
        cancel!(client.context.cancellation, "Language server stopped by its owner")
        transport = lock(client.mutex) do
            client.state = :closed
            for request in values(client.pending)
                isready(request.result) || put!(request.result, ShenScopeError(:language_state, "Language server was stopped"))
            end
            empty!(client.pending)
            empty!(client.documents)
            empty!(client.progress)
            client.transport
        end
        transport === nothing || mcp_transport_close!(transport)
    end
    monitor = client.monitor
    monitor === nothing || monitor === current_task() || wait(monitor)
    nothing
end

function language_client_status(client::LanguageClient, ctx::RuntimeContext)
    language_client_access(client, ctx; process=false)
    authorize!(ctx, :read, "language", ctx.root; reason="Inspect this conversation's language server status")
    lock(client.mutex) do
        Dict("schema" => LANGUAGE_SERVICE_SCHEMA, "server" => client.spec.name,
            "configuration_sha256" => client.spec.fingerprint, "state" => String(client.state),
            "generation" => client.generation, "languages" => copy(client.spec.languages),
            "capabilities" => deepcopy(client.capabilities), "open_documents" => length(client.documents),
            "pending_requests" => length(client.pending), "progress" => deepcopy(client.progress),
            "last_error" => client.last_error === nothing ? nothing : String(client.last_error),
            "automatic_restart" => false, "automatic_replay" => false,
            "server_process_os_isolated" => false, "unsaved_editor_buffers_supported" => false)
    end
end
