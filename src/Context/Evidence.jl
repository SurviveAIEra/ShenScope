function context_session!(manager::ContextManager, ctx::RuntimeContext)
    key = (ctx.root, ctx.session_id)
    session = lock(manager.mutex) do; get(manager.sessions, key, nothing); end
    if session === nothing
        session = load_session(ctx.state_dir, ctx.session_id)
        bind_context_session!(manager, session, ctx)
    end
    context_snapshot(session, ctx)
    session
end

function authorize_context_read!(ctx::RuntimeContext, tool::String)
    target = "session:" * ctx.session_id
    authorize!(ctx, :read, tool, target; reason="Read evidence from this conversation's original messages")
    request = PermissionRequest("context-read", :read, tool, target, "Read conversation evidence")
    permission_decision(ctx.permissions, request) == Deny && throw(ShenScopeError(:permission, "Conversation evidence is now denied"))
end

function context_source(manager::ContextManager, ctx::RuntimeContext, index::Int; expected_sha256=nothing,
        start_byte=1, max_bytes=16 * 1024)
    4 <= max_bytes <= 64 * 1024 && start_byte >= 1 || throw(ShenScopeError(:arguments, "Invalid context evidence page"))
    authorize_context_read!(ctx, "context.source")
    session = context_session!(manager, ctx)
    messages = context_snapshot(session, ctx)
    1 <= index <= length(messages) || throw(ShenScopeError(:context_source, "Context source message does not exist"))
    message = messages[index]
    reference = context_source_reference(message, index)
    expected_sha256 === nothing || expected_sha256 == reference["sha256"] ||
        throw(ShenScopeError(:conflict, "Context source digest does not match"))
    text = canonical(message_dict(message))
    start_byte <= ncodeunits(text) + 1 && (start_byte == ncodeunits(text) + 1 || isvalid(text, start_byte)) ||
        throw(ShenScopeError(:arguments, "Context page must begin on a UTF-8 boundary"))
    stop = min(ncodeunits(text) + 1, start_byte + max_bytes)
    while stop <= ncodeunits(text) && !isvalid(text, stop); stop -= 1; end
    page = start_byte == ncodeunits(text) + 1 ? "" : String(SubString(text, start_byte, prevind(text, stop)))
    Dict("source" => reference, "start_byte" => start_byte, "next_byte" => stop,
        "total_bytes" => ncodeunits(text), "complete" => stop == ncodeunits(text) + 1,
        "encoding" => "canonical_message_json", "text" => page)
end

function context_artifact(manager::ContextManager, ctx::RuntimeContext, hash::String; max_bytes=64 * 1024)
    occursin(r"^[0-9a-f]{64}$", hash) || throw(ShenScopeError(:arguments, "Invalid output artifact digest"))
    256 <= max_bytes <= 1024 * 1024 || throw(ShenScopeError(:arguments, "Invalid artifact preview capacity"))
    authorize_context_read!(ctx, "context.artifact")
    session = context_session!(manager, ctx)
    # Possession of a digest does not authorize an unrelated artifact.
    referenced = any(context_snapshot(session, ctx)) do message
        message.role == :tool || return false
        value = try parsejson(message.text) catch; return false end
        value isa AbstractDict && get(value, "artifact_sha256", nothing) == hash
    end
    referenced || throw(ShenScopeError(:context_scope, "Output artifact is not referenced by this conversation"))
    path = joinpath(ctx.state_dir, "outputs", valid_id(ctx.session_id), hash * ".json")
    text = read_scoped_text(ctx, ctx.state_dir, path, 4 * 1024 * 1024; tool="context.artifact",
        reason="Read the digest-checked original tool output", size_error=:context_capacity, encoding_error=:context_source)
    digest(text) == hash || throw(ShenScopeError(:context_source, "Output artifact failed integrity validation"))
    Dict("sha256" => hash, "bytes" => ncodeunits(text), "truncated" => ncodeunits(text) > max_bytes,
        "text" => context_excerpt(text, max_bytes))
end

function context_status(manager::ContextManager, ctx::RuntimeContext)
    session = context_session!(manager, ctx)
    messages = context_snapshot(session, ctx)
    checkpoint = saved_context_checkpoint(session, messages, manager.config)
    latest = lock(manager.mutex) do; deepcopy(get(manager.latest, (ctx.root, ctx.session_id), nothing)); end
    Dict("session_id" => session.id, "messages" => length(messages), "revision" => session.revision,
        "checkpoint" => checkpoint === nothing ? nothing : checkpoint_view(checkpoint), "latest" => latest,
        "auto_compact" => manager.config.auto_compact, "recovery_attempts" => manager.config.recovery_attempts)
end

function cleanup_context!(manager::ContextManager; session_id=nothing)
    jobs = lock(manager.mutex) do
        [job for job in values(manager.jobs) if session_id === nothing || job.context.session_id == session_id]
    end
    for job in jobs
        job.status == :running && cancel!(job.context.cancellation)
    end
    for job in jobs
        job.task === nothing || wait(job.task)
    end
    lock(manager.mutex) do
        for key in collect(keys(manager.sessions))
            session_id === nothing || key[2] == session_id || continue
            delete!(manager.sessions, key); delete!(manager.latest, key)
        end
        for job in jobs; delete!(manager.jobs, job.id); end
    end
    nothing
end
