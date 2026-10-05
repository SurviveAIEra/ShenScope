function language_transport(client::LanguageClient)
    spec = MCPServerSpec(client.spec.name, Dict("transport" => "stdio", "argv" => client.spec.argv,
        "cwd" => client.spec.cwd, "timeout" => client.spec.timeout, "connect_timeout" => client.spec.timeout,
        "max_message_bytes" => client.limits.maximum_message_bytes, "reconnect_attempts" => 0))
    generation = client.generation
    mcp_stdio_transport(spec, client.context, generation,
        message -> language_receive!(client, generation, message),
        cause -> language_connection_failed!(client, generation,
            cause isa Symbol ? cause : :language_transport);
        decoder_factory=()->LanguageFrameDecoder(; maximum_body=client.limits.maximum_message_bytes),
        decoder_feed=feed_language_frames!, decoder_finish=finish_language_frames!,
        permission_tool="language.process", permission_descriptor=language_process_target(client.spec, client.context))
end

function language_send!(client::LanguageClient, message::AbstractDict, ctx::RuntimeContext; timeout=client.spec.timeout)
    language_client_access(client, ctx)
    transport = lock(client.mutex) do
        client.state in (:connecting, :ready, :stopping) && client.transport !== nothing ||
            throw(ShenScopeError(:language_state, "Language server transport is unavailable"))
        client.transport
    end
    try
        mcp_transport_send!(transport, message, ctx; timeout, frame=language_frame)
    catch cause
        language_connection_failed!(client, client.generation, :language_transport)
        cause isa ShenScopeError && cause.code == :cancelled && rethrow()
        throw(ShenScopeError(:language_transport, "Language server transport failed; no automatic restart or replay"))
    end
    nothing
end

function language_notify!(client::LanguageClient, method::String, params::AbstractDict, ctx::RuntimeContext)
    language_send!(client, Dict("jsonrpc" => "2.0", "method" => method, "params" => params), ctx)
end

function language_connection_failed!(client::LanguageClient, generation::Int, code::Symbol)
    transport = lock(client.mutex) do
        generation == client.generation && !(client.state in (:failed, :closed)) || return nothing
        client.state = :failed
        client.last_error = code
        for request in values(client.pending)
            isready(request.result) || put!(request.result, ShenScopeError(:language_transport, "Language server connection ended"))
        end
        empty!(client.pending)
        for document in values(client.documents)
            empty!(document.diagnostic_items)
            document.diagnostic_received = false
        end
        client.transport
    end
    transport === nothing || mcp_transport_close!(transport)
    nothing
end
