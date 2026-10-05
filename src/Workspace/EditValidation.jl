function workspace_edit_location(value, source::SourceMap)
    workspace_edit_fields(value, ["file", "start_line", "end_line"],
        ["start_column", "end_column", "column_unit"], "workspace edit range")
    value["file"] == source.path && get(value, "column_unit", "utf8_byte") == "utf8_byte" ||
        throw(ShenScopeError(:workspace_edit, "Workspace edit range has the wrong file or column encoding"))
    first_line = language_integer(value["start_line"], "edit start line", 1, length(source.starts))
    last_line = language_integer(value["end_line"], "edit end line", first_line, length(source.starts))
    first_column = language_integer(get(value, "start_column", 1), "edit start column", 1, 8*1024^2)
    last_column = language_integer(get(value, "end_column", 1), "edit end column", 1, 8*1024^2)
    location = SourceRange(source.path, first_line, last_line; start_column=first_column, end_column=last_column)
    source_range_indices(source, location)
    location
end

function workspace_validate_text_edits(value, snapshot::WorkspaceSourceSnapshot, limits::WorkspaceEditLimits)
    value isa AbstractVector && 1 <= length(value) <= limits.maximum_edits ||
        throw(ShenScopeError(:workspace_edit, "Workspace file requires a bounded nonempty edit array"))
    result = WorkspaceTextEdit[]
    replacement_bytes = 0
    for row in value
        workspace_edit_fields(row, ["location", "new_text"], String[], "workspace text edit")
        location = workspace_edit_location(row["location"], snapshot.source)
        first, after = source_range_indices(snapshot.source, location)
        text = workspace_edit_text(row["new_text"], "workspace replacement", limits.maximum_file_bytes; empty=true)
        replacement_bytes += ncodeunits(text)
        replacement_bytes <= limits.maximum_replacement_bytes ||
            throw(ShenScopeError(:capacity, "Workspace replacement text exceeds capacity"))
        push!(result, WorkspaceTextEdit(location, first, after, text))
    end
    sort!(result; by=edit -> (edit.first_byte, edit.after_byte))
    for index in 2:length(result)
        prior, current = result[index-1], result[index]
        prior.after_byte <= current.first_byte && prior.first_byte != current.first_byte ||
            throw(ShenScopeError(:conflict, "Workspace edits overlap or insert at the same source position"))
    end
    result
end

function workspace_apply_text_edits(source::String, edits::Vector{WorkspaceTextEdit}; maximum_bytes=4*1024^2)
    predicted = ncodeunits(source) + sum(ncodeunits(edit.new_text) - (edit.after_byte-edit.first_byte) for edit in edits; init=0)
    0 <= predicted <= maximum_bytes || throw(ShenScopeError(:capacity, "Edited workspace source exceeds file capacity"))
    output = IOBuffer(; maxsize=maximum_bytes, sizehint=predicted)
    bytes = codeunits(source)
    cursor = 1
    for edit in edits
        cursor <= edit.first_byte <= edit.after_byte <= length(bytes)+1 ||
            throw(ShenScopeError(:workspace_edit, "Workspace edit byte intervals are inconsistent"))
        cursor < edit.first_byte && write(output, @view bytes[cursor:edit.first_byte-1])
        write(output, edit.new_text)
        cursor = edit.after_byte
    end
    cursor <= length(bytes) && write(output, @view bytes[cursor:end])
    result = String(take!(output))
    isvalid(result) && ncodeunits(result) == predicted || throw(ShenScopeError(:workspace_edit, "Edited source encoding is inconsistent"))
    result
end

function workspace_validate_file_edit(row, ctx::RuntimeContext, limits::WorkspaceEditLimits)
    workspace_edit_fields(row, ["path", "expected_sha256", "edits"], ["line_break_policy"], "workspace file proposal")
    path = workspace_edit_text(row["path"], "workspace edit file", 4096)
    hash = workspace_edit_hash(row["expected_sha256"], "workspace edit source hash")
    policy = get(row, "line_break_policy", "unicode_source")
    policy in ("unicode_source", "lsp_cr_lf") || throw(ShenScopeError(:workspace_edit, "Unsupported edit line-break policy"))
    source = read_workspace_snapshot(ctx, path; expected_sha256=hash, maximum_bytes=limits.maximum_file_bytes,
        tool="workspace.preview", unicode_line_separators=policy == "unicode_source")
    edits = workspace_validate_text_edits(row["edits"], source, limits)
    after = workspace_apply_text_edits(source.source.source, edits; maximum_bytes=limits.maximum_file_bytes)
    mode = UInt(filemode(source.absolute) & 0o777)
    WorkspaceFileEdit(source, edits, after, digest(after), mode)
end
