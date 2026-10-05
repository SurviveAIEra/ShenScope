function sarif_artifact_location(state::SarifParseContext, value::AbstractDict)
    location = sarif_object(value, "SARIF artifact location")
    if haskey(location, "index")
        index = language_integer(location["index"], "SARIF artifact index", 0, length(state.artifacts)-1)
        artifact = sarif_object(state.artifacts[index+1], "indexed SARIF artifact")
        indexed = sarif_object(get(artifact, "location", nothing), "indexed SARIF artifact location")
        for key in ("uri", "uriBaseId")
            haskey(location, key) && get(indexed, key, nothing) != location[key] &&
                throw(ShenScopeError(:sarif, "SARIF artifact index and URI disagree"))
        end
        return indexed
    end
    location
end

function sarif_resolve_uri(state::SarifParseContext, value::AbstractDict; seen=Set{String}())
    location = sarif_artifact_location(state, value)
    uri = workspace_edit_text(get(location, "uri", nothing), "SARIF artifact URI", 16*1024; empty=true)
    !occursin('?', uri) && !occursin('#', uri) && !occursin('\\', uri) ||
        throw(ShenScopeError(:sarif, "SARIF URI contains unsupported query, fragment or separator"))
    if startswith(uri, "file://")
        absolute, _ = language_workspace_uri(state.context, uri; must_exist=false)
        return absolute
    end
    occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri) &&
        throw(ShenScopeError(:sarif, "Non-file SARIF URI is unsupported"))
    path = language_percent_decode(uri)
    !occursin('\\', path) && !occursin('\0', path) ||
        throw(ShenScopeError(:sarif, "SARIF decoded URI has an invalid separator or NUL"))
    isabspath(path) && throw(ShenScopeError(:sarif, "Absolute SARIF paths require file URIs"))
    base_id = get(location, "uriBaseId", nothing)
    directory = state.context.root
    if base_id !== nothing
        id = workspace_edit_text(base_id, "SARIF URI base ID", 256)
        id in seen && throw(ShenScopeError(:sarif, "SARIF URI base references contain a cycle"))
        length(seen) < 16 || throw(ShenScopeError(:sarif, "SARIF URI base references exceed depth capacity"))
        bases = get(state.run, "originalUriBaseIds", Dict())
        haskey(bases, id) || throw(ShenScopeError(:sarif, "SARIF URI base ID is undeclared"))
        push!(seen, id)
        directory = sarif_resolve_uri(state, sarif_object(bases[id], "SARIF URI base"); seen)
        isdir(directory) || throw(ShenScopeError(:sarif, "SARIF URI base is not a workspace directory"))
    end
    absolute, _ = workspace_snapshot_path(state.context, joinpath(directory, path); must_exist=false)
    absolute
end

function sarif_source_location(state::SarifParseContext, value)
    location = sarif_object(value, "SARIF location")
    physical = sarif_object(get(location, "physicalLocation", nothing), "SARIF physical location")
    artifact = sarif_object(get(physical, "artifactLocation", nothing), "SARIF source artifact")
    absolute = sarif_resolve_uri(state, artifact)
    path = replace(relpath(absolute, state.context.root), '\\' => '/')
    snapshot = get(state.sources, path, nothing)
    snapshot === nothing && return nothing
    region = get(physical, "region", nothing)
    region === nothing && return (snapshot, nothing, "unlocated")
    region = sarif_object(region, "SARIF source region")
    start = get(region, "startLine", nothing)
    start === nothing && return (snapshot, nothing, "unlocated")
    source = snapshot.source
    first_line = language_integer(start, "SARIF start line", 1, length(source.starts))
    last_line = language_integer(get(region, "endLine", first_line), "SARIF end line", first_line, length(source.starts))
    if haskey(region, "startColumn") && haskey(region, "endColumn")
        first = language_integer(region["startColumn"], "SARIF start column", 1, 8*1024^2)
        last = language_integer(region["endColumn"], "SARIF end column", 1, 8*1024^2)
        if state.column_kind == "utf16CodeUnits"
            first = utf16_byte_column(source, first_line, first-1)
            last = utf16_byte_column(source, last_line, last-1)
        else
            first = scalar_byte_column(source, first_line, first-1)
            last = scalar_byte_column(source, last_line, last-1)
        end
        precision = "explicit_source_range"
    else
        first = 1
        last = source.ends[last_line]-source.starts[last_line]+1
        precision = "derived_reported_lines"
    end
    range = SourceRange(path, first_line, last_line; start_column=first, end_column=last)
    source_range_indices(source, range)
    snapshot, range, precision
end
