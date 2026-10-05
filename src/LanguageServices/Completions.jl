function language_completion_text_edit(value, snapshot::WorkspaceSourceSnapshot)
    value isa AbstractDict && haskey(value, "newText") || throw(ShenScopeError(:language_protocol, "Completion edit lacks replacement text"))
    text = language_text(value["newText"], "completion replacement", 128*1024; empty=true)
    if haskey(value, "range")
        location = language_range(snapshot.source, value["range"])
        return Dict("location" => range_dict(location), "new_text" => text)
    end
    haskey(value, "insert") && haskey(value, "replace") ||
        throw(ShenScopeError(:language_protocol, "Completion edit lacks a range or insert/replace ranges"))
    insert = language_range(snapshot.source, value["insert"])
    replace = language_range(snapshot.source, value["replace"])
    first, after = source_range_indices(snapshot.source, insert)
    start, finish = source_range_indices(snapshot.source, replace)
    first == start && after <= finish && insert.start_line == insert.end_line && replace.start_line == replace.end_line ||
        throw(ShenScopeError(:language_protocol, "Completion insert/replace ranges are inconsistent"))
    Dict("insert_location" => range_dict(insert), "replace_location" => range_dict(replace), "new_text" => text)
end

function language_completion_item(value, snapshot::WorkspaceSourceSnapshot)
    value isa AbstractDict && haskey(value, "label") || throw(ShenScopeError(:language_protocol, "Completion requires a label"))
    label = language_text(value["label"], "completion label", 4096)
    format = language_integer(get(value, "insertTextFormat", 1), "completion text format", 1, 2)
    kind = get(value, "kind", nothing)
    kind === nothing || (kind = language_integer(kind, "completion kind", 1, 25))
    result = Dict{String,Any}("label" => label, "kind" => kind,
        "insert_text_format" => format == 2 ? "snippet" : "plain_text",
        "requires_command_execution" => haskey(value, "command"), "automatic_execution" => false)
    for (remote, localkey, maximum) in (("detail","detail",8192), ("sortText","sort_text",4096),
            ("filterText","filter_text",4096), ("insertText","insert_text",128*1024))
        haskey(value, remote) && (result[localkey] = language_text(value[remote], "completion " * localkey, maximum; empty=true))
    end
    haskey(value, "documentation") && (result["documentation"] = language_signature_documentation(value["documentation"]))
    if haskey(value, "textEdit")
        result["text_edit"] = language_completion_text_edit(value["textEdit"], snapshot)
    end
    additional = get(value, "additionalTextEdits", Any[])
    additional isa AbstractVector && length(additional) <= 128 || throw(ShenScopeError(:language_protocol, "Completion has too many additional edits"))
    result["additional_edits"] = [language_completion_text_edit(edit, snapshot) for edit in additional]
    # Snippets and commands are kept as reported choices. The generic edit
    # engine must never paste snippet control syntax as an ordinary fix.
    result["plain_edit_applicable"] = format == 1 && !haskey(value, "command")
    result["id"] = digest(canonical(result))
    result
end

function normalize_language_completions(value, snapshot::WorkspaceSourceSnapshot; maximum=100)
    incomplete = false
    defaults = Dict{String,Any}()
    if value === nothing
        rows = Any[]
    elseif value isa AbstractVector
        rows = value
    elseif value isa AbstractDict
        get(value, "isIncomplete", nothing) isa Bool && get(value, "items", nothing) isa AbstractVector ||
            throw(ShenScopeError(:language_protocol, "Completion list requires items and isIncomplete"))
        rows = value["items"]
        incomplete = value["isIncomplete"]
        defaults = get(value, "itemDefaults", Dict{String,Any}())
        defaults isa AbstractDict || throw(ShenScopeError(:language_protocol, "Invalid completion defaults"))
    else
        throw(ShenScopeError(:language_protocol, "Invalid completion response"))
    end
    length(rows) <= 16_384 || throw(ShenScopeError(:capacity, "Completion input exceeds capacity"))
    items = Dict{String,Any}[]
    omitted = 0
    for value in rows
        if length(items) >= maximum
            omitted += 1
            continue
        end
        value isa AbstractDict || throw(ShenScopeError(:language_protocol, "Completion item must be an object"))
        item = deepcopy(Dict{String,Any}(value))
        haskey(item, "insertTextFormat") || !haskey(defaults, "insertTextFormat") || (item["insertTextFormat"] = defaults["insertTextFormat"])
        # Unsupported default edit ranges are disclosed rather than silently
        # interpreted at an arbitrary source position.
        normalized = language_completion_item(item, snapshot)
        normalized["unsupported_default_edit_range"] = haskey(defaults, "editRange") && !haskey(item, "textEdit")
        normalized["unsupported_default_edit_range"] && (normalized["plain_edit_applicable"] = false)
        push!(items, normalized)
    end
    Dict("items" => items, "server_list_incomplete" => incomplete, "reported_items" => length(rows),
        "omitted_items" => omitted, "path" => snapshot.path, "source_sha256" => snapshot.sha256,
        "automatic_insertion" => false, "projection_truncated" => omitted > 0)
end
