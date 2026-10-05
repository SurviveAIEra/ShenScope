function language_percent_decode(value::AbstractString)
    encoded = codeunits(value)
    output = UInt8[]
    cursor = 1
    while cursor <= length(encoded)
        byte = encoded[cursor]
        if byte == UInt8('%')
            cursor + 2 <= length(encoded) || throw(ShenScopeError(:language_uri, "Truncated URI escape"))
            pair = String(UInt8[encoded[cursor+1], encoded[cursor+2]])
            occursin(r"^[0-9a-fA-F]{2}$", pair) || throw(ShenScopeError(:language_uri, "Invalid URI escape"))
            decoded = parse(UInt8, pair; base=16)
            decoded == 0 && throw(ShenScopeError(:language_uri, "URI contains a null byte"))
            push!(output, decoded)
            cursor += 3
        else
            push!(output, byte)
            cursor += 1
        end
    end
    text = String(output)
    isvalid(text) || throw(ShenScopeError(:language_uri, "URI is not UTF-8"))
    text
end

function language_workspace_uri(ctx::RuntimeContext, value; must_exist=true)
    uri = language_text(value, "language-service file URI", 16*1024)
    startswith(uri, "file://") || throw(ShenScopeError(:language_uri, "Only workspace file URIs are supported"))
    body = uri[8:end]
    startswith(body, "localhost/") && (body = body[10:end])
    startswith(body, "/") && !occursin('?', body) && !occursin('#', body) ||
        throw(ShenScopeError(:language_uri, "Remote hosts and query-bearing file URIs are unsupported"))
    path = language_percent_decode(body)
    Sys.iswindows() && occursin(r"^/[A-Za-z]:/", path) && (path = path[2:end])
    absolute, relative = workspace_snapshot_path(ctx, path; must_exist)
    absolute, relative
end

function language_source_uri(ctx::RuntimeContext, path::AbstractString)
    absolute, _ = workspace_snapshot_path(ctx, path)
    mcp_file_uri(absolute)
end

function language_range(source::SourceMap, value)
    try
        compiler_range(source, value)
    catch cause
        cause isa ShenScopeError || rethrow()
        throw(ShenScopeError(:language_position, "Language server range is outside the verified UTF-16 source"))
    end
end

function language_cursor(source::SourceMap, line, character)
    first_line = language_integer(line, "cursor line", 0, length(source.starts)-1)
    offset = language_integer(character, "UTF-16 cursor character", 0, 8*1024^2)
    utf16_byte_column(source, first_line + 1, offset)
    Dict("line" => first_line, "character" => offset)
end
