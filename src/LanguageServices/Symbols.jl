function language_symbol_kind(value)
    kind = language_integer(value, "language symbol kind", 1, 26)
    names = ("file", "module", "namespace", "package", "class", "method", "property", "field",
        "constructor", "enum", "interface", "function", "variable", "constant", "string", "number",
        "boolean", "array", "object", "key", "null", "enum_member", "struct", "event", "operator", "type_parameter")
    names[kind]
end

function normalize_language_symbols(value, sources::LanguageResultSources; primary=nothing, maximum=1000)
    rows = value === nothing ? Any[] : value
    rows isa AbstractVector && length(rows) <= 16_384 ||
        throw(ShenScopeError(:language_protocol, "Language symbol response must be a bounded array"))
    selected = Dict{String,Any}[]
    visited = Ref(0)
    function visit(row, parent, depth)
        visited[] += 1
        visited[] <= 16_384 && depth <= 32 ||
            throw(ShenScopeError(:language_protocol, "Language symbol hierarchy exceeds capacity"))
        workspace_source_checkpoint(sources.context)
        row isa AbstractDict && haskey(row, "name") && haskey(row, "kind") ||
            throw(ShenScopeError(:language_protocol, "Language symbol lacks name or kind"))
        if length(selected) >= maximum
            language_omit!(sources, "result_capacity")
            return
        end
        name = language_text(row["name"], "language symbol name", 4096)
        kind = language_symbol_kind(row["kind"])
        if haskey(row, "location")
            location = language_result_location(row["location"], sources)
            location === nothing && return
        else
            primary === nothing && throw(ShenScopeError(:language_protocol, "Hierarchical symbol has no owned document"))
            haskey(row, "range") && haskey(row, "selectionRange") ||
                throw(ShenScopeError(:language_protocol, "Document symbol has no source ranges"))
            outer = language_range(primary.source, row["range"])
            selection = language_range(primary.source, row["selectionRange"])
            first, last = source_range_indices(primary.source, outer)
            start, finish = source_range_indices(primary.source, selection)
            first <= start <= finish <= last ||
                throw(ShenScopeError(:language_protocol, "Symbol selection escapes its declaration range"))
            location = Dict("path" => primary.path, "source_sha256" => primary.sha256,
                "location" => range_dict(selection), "declaration_range" => range_dict(outer))
        end
        identity = digest(canonical([location["path"], name, kind, location["location"], parent]))
        item = Dict{String,Any}("id" => identity, "name" => name, "kind" => kind,
            "parent_id" => parent, "location" => location)
        if haskey(row, "detail") && row["detail"] !== nothing
            item["detail"] = language_text(row["detail"], "symbol detail", 4096; empty=true)
        end
        push!(selected, item)
        children = get(row, "children", Any[])
        children isa AbstractVector && length(children) <= 4096 ||
            throw(ShenScopeError(:language_protocol, "Invalid symbol children"))
        for child in children
            visit(child, identity, depth + 1)
        end
    end
    for row in rows
        visit(row, nothing, 0)
    end
    Dict("items" => selected, "visited_items" => visited[], "omitted" => deepcopy(sources.omitted),
        "projection_truncated" => !isempty(sources.omitted), "symbols_are_server_reports" => true)
end
