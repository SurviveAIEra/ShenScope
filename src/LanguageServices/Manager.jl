function language_service_key(ctx::RuntimeContext, name::String)
    digest(canonical([ctx.root, ctx.state_dir, ctx.session_id, name]))
end

function start_language_service!(manager::LanguageServiceManager, spec::LanguageServerSpec, ctx::RuntimeContext)
    key = language_service_key(ctx, spec.name)
    client = LanguageClient(spec, ctx; limits=manager.limits)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:language_state, "Language-service manager is closed"))
        haskey(manager.clients, key) && throw(ShenScopeError(:conflict, "Stop the existing named language server before starting another"))
        length(manager.clients) < manager.limits.maximum_servers ||
            throw(ShenScopeError(:capacity, "Language-service server capacity reached"))
        manager.clients[key] = client
    end
    try
        start_language_client!(client)
    catch
        stop_language_client!(client; graceful=false)
        lock(manager.mutex) do
            get(manager.clients, key, nothing) === client && delete!(manager.clients, key)
        end
        rethrow()
    end
end

function owned_language_client(manager::LanguageServiceManager, name::AbstractString, ctx::RuntimeContext)
    identifier = language_text(name, "language server name", 64)
    client = lock(manager.mutex) do
        get(manager.clients, language_service_key(ctx, identifier), nothing)
    end
    client === nothing && throw(ShenScopeError(:language_state, "Start this conversation's named language server first"))
    operation_scope(client.context) == operation_scope(ctx) || throw(ShenScopeError(:permission, "Foreign language server"))
    client
end

function list_language_services(manager::LanguageServiceManager, ctx::RuntimeContext)
    authorize!(ctx, :read, "language", ctx.root; reason="List this conversation's language servers")
    clients = lock(manager.mutex) do
        [client for client in values(manager.clients) if operation_scope(client.context) == operation_scope(ctx)]
    end
    Dict("servers" => [language_client_status(client, ctx) for client in sort!(clients; by=client -> client.spec.name)],
        "automatic_start" => false, "automatic_download" => false)
end

function stop_language_service!(manager::LanguageServiceManager, name::AbstractString, ctx::RuntimeContext)
    client = owned_language_client(manager, name, ctx)
    stop_language_client!(client)
    lock(manager.mutex) do
        key = language_service_key(ctx, client.spec.name)
        get(manager.clients, key, nothing) === client && delete!(manager.clients, key)
    end
    Dict("stopped" => true, "server" => client.spec.name, "automatic_restart" => false)
end

function close_language_services!(manager::LanguageServiceManager)
    clients = lock(manager.mutex) do
        manager.closed = true
        collect(values(manager.clients))
    end
    for client in clients
        stop_language_client!(client; graceful=false)
    end
    lock(manager.mutex) do
        empty!(manager.clients)
    end
    nothing
end
