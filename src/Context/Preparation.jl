function trim_tool_result(result::ToolResult; max_bytes=32 * 1024, artifact_sha256=nothing)
    max_bytes >= 1024 || throw(ArgumentError("Tool result capacity is too small"))
    value = Dict{String,Any}("ok" => result.ok, "value" => result.value, "error" => result.error)
    artifact_sha256 === nothing || (value["artifact_sha256"] = artifact_sha256)
    raw = canonical(value)
    ncodeunits(raw) <= max_bytes && return raw
    envelope = Dict{String,Any}("ok" => result.ok, "truncated" => true,
        "original_bytes" => ncodeunits(raw), "preview" => context_excerpt(raw, max_bytes ÷ 2),
        "error" => result.error)
    artifact_sha256 === nothing || (envelope["artifact_sha256"] = artifact_sha256)
    text = canonical(envelope)
    if ncodeunits(text) > max_bytes
        envelope["preview"] = context_excerpt(raw, max_bytes ÷ 4)
        envelope["error"] = result.error === nothing ? nothing : context_excerpt(result.error, 512)
        text = canonical(envelope)
    end
    ncodeunits(text) <= max_bytes || throw(ShenScopeError(:context_capacity, "Tool result envelope exceeds capacity"))
    text
end

function archive_output!(ctx::RuntimeContext, result::ToolResult)
    raw = canonical(Dict("id" => result.id, "ok" => result.ok, "value" => result.value, "error" => result.error))
    ncodeunits(raw) <= 4 * 1024 * 1024 || begin
        emit!(ctx, :output_archive_skipped, Dict("id" => result.id, "code" => "capacity"))
        return nothing
    end
    hash = digest(raw)
    path = joinpath(ctx.state_dir, "outputs", valid_id(ctx.session_id), hash * ".json")
    try
        authorize!(ctx, :persistence, "context.archive", "session:" * ctx.session_id;
            reason="Archive an original tool result for later context recovery")
        request = PermissionRequest("archive-output", :persistence, "context.archive", "session:" * ctx.session_id, "Save tool output")
        permission_decision(ctx.permissions, request) == Deny && throw(ShenScopeError(:permission, "Output persistence is now denied"))
        workspace_path(ctx.state_dir, path) == path || throw(ShenScopeError(:permission, "Output archive may not use symlinks"))
        if isfile(path)
            filesize(path) <= 4 * 1024 * 1024 && digest(read(path, String)) == hash ||
                throw(ShenScopeError(:context_source, "Existing output archive failed integrity validation"))
        else
            atomic_write(path, raw)
        end
    catch error
        if error isa ShenScopeError && error.code == :permission
            emit!(ctx, :output_archive_skipped, Dict("id" => result.id, "code" => "permission"))
            return nothing
        end
        rethrow()
    end
    hash
end
