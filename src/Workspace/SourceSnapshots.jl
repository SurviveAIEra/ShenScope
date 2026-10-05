struct WorkspaceSourceSnapshot
    root::String
    path::String
    absolute::String
    sha256::String
    source::SourceMap
    identity::Tuple
end

function workspace_snapshot_path(ctx::RuntimeContext, requested::AbstractString; must_exist=true)
    isvalid(requested) && !isempty(requested) && ncodeunits(requested) <= 4096 &&
        !occursin('\0', requested) || throw(ShenScopeError(:source, "Invalid workspace source path"))
    lexical = normpath(isabspath(requested) ? requested : joinpath(ctx.root, requested))
    absolute = workspace_path(ctx.root, requested; must_exist)
    absolute == lexical && !islink(absolute) ||
        throw(ShenScopeError(:permission, "Workspace source may not follow symlinks"))
    relative = replace(relpath(absolute, ctx.root), '\\' => '/')
    absolute, relative
end

workspace_source_identity(info) = (info.device, info.inode, info.size, info.mtime, info.ctime)

function workspace_source_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
    end
end

function workspace_source_permission(ctx::RuntimeContext, absolute::String, tool::String;
        allow_ask=true, reason="Read current workspace source")
    request = PermissionRequest("workspace-source-read", :read, tool, absolute, reason)
    decision = permission_decision(ctx.permissions, request)
    decision == Deny && throw(ShenScopeError(:permission, "Workspace source read is denied"))
    !allow_ask && decision != Allow &&
        throw(ShenScopeError(:permission, "Use an asynchronous operation to approve this source read"))
    allow_ask && authorize!(ctx, :read, tool, absolute; reason)
    nothing
end

function read_workspace_snapshot(ctx::RuntimeContext, requested::AbstractString;
        expected_sha256=nothing, maximum_bytes=8*1024^2, tool="workspace.source", allow_ask=true)
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 1 <= maximum_bytes <= 8*1024^2 ||
        throw(ShenScopeError(:source, "Invalid source snapshot capacity"))
    expected_sha256 === nothing || expected_sha256 isa String &&
        occursin(r"^[0-9a-f]{64}$", expected_sha256) ||
        throw(ShenScopeError(:source, "Invalid expected source hash"))
    workspace_source_checkpoint(ctx)
    absolute, relative = workspace_snapshot_path(ctx, requested)
    workspace_source_permission(ctx, absolute, String(tool); allow_ask)
    before = stat(absolute)
    isfile(before) && before.size <= maximum_bytes ||
        throw(ShenScopeError(:source, "Workspace source exceeds snapshot capacity"))
    bytes = open(absolute, "r") do input
        read(input, Int(maximum_bytes) + 1)
    end
    after = stat(absolute)
    workspace_source_identity(before) == workspace_source_identity(after) &&
        length(bytes) <= maximum_bytes && workspace_snapshot_path(ctx, relative)[1] == absolute ||
        throw(ShenScopeError(:conflict, "Workspace source changed while it was read"))
    text = String(bytes)
    isvalid(text) && !occursin('\0', text) ||
        throw(ShenScopeError(:source, "Workspace source is not UTF-8 text"))
    hash = digest(text)
    expected_sha256 === nothing || hash == expected_sha256 ||
        throw(ShenScopeError(:stale_source, "Workspace source differs from the reported source version"))
    workspace_source_checkpoint(ctx)
    permission_decision(ctx.permissions, PermissionRequest("workspace-source-recheck", :read,
        String(tool), absolute, "Recheck source access")) != Deny ||
        throw(ShenScopeError(:permission, "Workspace source access was revoked during the read"))
    WorkspaceSourceSnapshot(ctx.root, relative, absolute, hash, SourceMap(relative, text),
        workspace_source_identity(after))
end

function verify_workspace_snapshot(snapshot::WorkspaceSourceSnapshot, ctx::RuntimeContext;
        tool="workspace.source", allow_ask=true)
    snapshot.root == ctx.root || throw(ShenScopeError(:permission, "Source snapshot belongs to another workspace"))
    current = read_workspace_snapshot(ctx, snapshot.path; expected_sha256=snapshot.sha256,
        tool, allow_ask)
    current.sha256 == snapshot.sha256 || throw(ShenScopeError(:stale_source, "Source snapshot is stale"))
    current
end

function workspace_snapshot_view(snapshot::WorkspaceSourceSnapshot)
    Dict("path" => snapshot.path, "sha256" => snapshot.sha256,
        "bytes" => ncodeunits(snapshot.source.source), "lines" => length(snapshot.source.starts),
        "encoding" => "utf8", "column_unit" => "utf8_byte")
end

function workspace_source_excerpt(snapshot::WorkspaceSourceSnapshot, location::SourceRange;
        context_lines=3, maximum_bytes=32*1024)
    location.file == snapshot.path || throw(ShenScopeError(:source, "Source range belongs to another file"))
    context_lines isa Integer && !(context_lines isa Bool) && 0 <= context_lines <= 20 &&
        maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 128 <= maximum_bytes <= 64*1024 ||
        throw(ShenScopeError(:source, "Invalid source preview capacity"))
    source_range_indices(snapshot.source, location)
    first_line = max(1, location.start_line - context_lines)
    last_line = min(length(snapshot.source.starts), location.end_line + context_lines)
    rows = Dict{String,Any}[]
    bytes = 0
    truncated = false
    for line in first_line:last_line
        start, ending = source_line_bounds(snapshot.source, line)
        text = String(SubString(snapshot.source.source, start, prevind(snapshot.source.source, ending)))
        available = Int(maximum_bytes) - bytes
        if ncodeunits(text) > available
            available > 0 && push!(rows, Dict("line" => line, "text" => cliptext(text, available), "truncated" => true))
            truncated = true
            break
        end
        push!(rows, Dict("line" => line, "text" => text, "truncated" => false))
        bytes += ncodeunits(text)
    end
    Dict("path" => snapshot.path, "sha256" => snapshot.sha256, "location" => range_dict(location),
        "lines" => rows, "preview_truncated" => truncated, "source_hash_verified" => true)
end

function source_editor_range(source::SourceMap, location::SourceRange)
    source.path == location.file || throw(ShenScopeError(:source_position, "Source range file mismatch"))
    source_range_indices(source, location)
    Dict("start" => Dict("line" => location.start_line - 1,
            "character" => byte_utf16_character(source, location.start_line, location.start_column)),
        "end" => Dict("line" => location.end_line - 1,
            "character" => byte_utf16_character(source, location.end_line, location.end_column)))
end
