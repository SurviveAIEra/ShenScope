function language_text_edits(value, snapshot::WorkspaceSourceSnapshot; maximum=1024)
    value isa AbstractVector && length(value) <= maximum ||
        throw(ShenScopeError(:language_protocol, "Language edits must be a bounded array"))
    rows = Dict{String,Any}[]
    total = 0
    for edit in value
        language_fields(edit, ["range", "newText"], ["annotationId"], "language text edit")
        text = language_text(edit["newText"], "replacement text", 2*1024^2; empty=true)
        total += ncodeunits(text)
        total <= 4*1024^2 || throw(ShenScopeError(:capacity, "Language edit text exceeds proposal capacity"))
        location = language_range(snapshot.source, edit["range"])
        push!(rows, Dict("location" => range_dict(location), "new_text" => text))
    end
    Dict("path" => snapshot.path, "expected_sha256" => snapshot.sha256,
        "line_break_policy" => "lsp_cr_lf", "edits" => rows)
end

function language_format_edit(response, snapshot::WorkspaceSourceSnapshot)
    edits = response === nothing ? Any[] : response
    Dict("files" => [language_text_edits(edits, snapshot)], "requires_explicit_apply" => true,
        "resource_operations_supported" => false, "command_execution_supported" => false)
end

function language_workspace_edit(response, client::LanguageClient, ctx::RuntimeContext;
        sources=LanguageResultSources(ctx))
    response === nothing && return Dict("files" => Any[], "requires_explicit_apply" => true)
    language_fields(response, String[], ["changes", "documentChanges", "changeAnnotations"], "workspace edit")
    haskey(response, "changes") && haskey(response, "documentChanges") &&
        throw(ShenScopeError(:language_protocol, "Workspace edit cannot mix change representations"))
    specifications = Dict{String,Tuple{WorkspaceSourceSnapshot,Any}}()
    function add(uri, edits, expected_version=nothing)
        _, path = language_workspace_uri(ctx, uri)
        haskey(specifications, path) && throw(ShenScopeError(:language_protocol, "Workspace edit repeats a file"))
        length(specifications) < 64 || throw(ShenScopeError(:capacity, "Workspace edit changes too many files"))
        document = lock(client.mutex) do
            get(client.documents, path, nothing)
        end
        if expected_version !== nothing
            version = language_integer(expected_version, "workspace edit document version", 0, 2^31-1)
            document !== nothing && document.version == version ||
                throw(ShenScopeError(:conflict, "Workspace edit uses a stale or unopened document version"))
        end
        snapshot = if document === nothing
            read_workspace_snapshot(ctx, path; tool="language.source", maximum_bytes=2*1024^2, unicode_line_separators=false)
        else
            verify_workspace_snapshot(document.snapshot, ctx; tool="language.source")
        end
        specifications[path] = (snapshot, edits)
        if !haskey(sources.cache, path)
            sources.bytes+ncodeunits(snapshot.source.source) <= sources.maximum_bytes &&
                length(sources.cache) < sources.maximum_files ||
                throw(ShenScopeError(:capacity, "Language edit sources exceed projection capacity"))
            sources.cache[path] = snapshot
            sources.bytes += ncodeunits(snapshot.source.source)
        elseif sources.cache[path].sha256 != snapshot.sha256
            throw(ShenScopeError(:stale_source, "Language edit source changed during projection"))
        end
    end
    if haskey(response, "changes")
        changes = response["changes"]
        changes isa AbstractDict && length(changes) <= 64 || throw(ShenScopeError(:language_protocol, "Invalid workspace edit changes"))
        for uri in sort!(collect(keys(changes)))
            add(uri, changes[uri])
        end
    elseif haskey(response, "documentChanges")
        changes = response["documentChanges"]
        changes isa AbstractVector && length(changes) <= 64 || throw(ShenScopeError(:language_protocol, "Invalid versioned workspace edits"))
        for change in changes
            # Create, delete and rename operations require a separate reviewed
            # filesystem contract. Do not reinterpret them as ordinary edits.
            language_fields(change, ["textDocument", "edits"], String[], "versioned document edit")
            language_fields(change["textDocument"], ["uri", "version"], String[], "versioned edit document")
            add(change["textDocument"]["uri"], change["edits"], change["textDocument"]["version"])
        end
    end
    files = [language_text_edits(specifications[path][2], specifications[path][1]) for path in sort!(collect(keys(specifications)))]
    bounded_canonical_json(files; maximum=4*1024^2, max_depth=16, max_nodes=32_000)
    versions = verify_language_result_sources!(sources)
    Dict("files" => files, "requires_explicit_apply" => true,
        "source_versions" => versions, "source_versions_verified" => true,
        "resource_operations_supported" => false, "command_execution_supported" => false,
        "annotations_are_server_metadata" => haskey(response, "changeAnnotations"))
end

function normalize_language_code_actions(response, client::LanguageClient, ctx::RuntimeContext;
        maximum=100, sources=LanguageResultSources(ctx))
    rows = response === nothing ? Any[] : response
    rows isa AbstractVector && length(rows) <= 4096 || throw(ShenScopeError(:language_protocol, "Invalid code action response"))
    actions = Dict{String,Any}[]
    omitted = 0
    for row in rows
        if length(actions) >= maximum
            omitted += 1
            continue
        end
        row isa AbstractDict && haskey(row, "title") || throw(ShenScopeError(:language_protocol, "Code action has no title"))
        title = language_text(row["title"], "code action title", 1024)
        disabled = haskey(row, "disabled")
        has_command = haskey(row, "command")
        proposal = haskey(row, "edit") && !disabled && !has_command ? language_workspace_edit(row["edit"], client, ctx; sources) : nothing
        action = Dict{String,Any}("title" => title,
            "kind" => language_text(get(row, "kind", ""), "code action kind", 256; empty=true),
            "requires_command_execution" => has_command, "disabled" => disabled,
            "applicable_edit_proposal" => proposal, "automatic_execution" => false)
        disabled && (action["disabled_reason"] = cliptext(string(get(row["disabled"], "reason", "Disabled by the language server")), 1024))
        action["id"] = digest(canonical(action))
        push!(actions, action)
    end
    Dict("actions" => actions, "reported_items" => length(rows), "omitted_items" => omitted,
        "command_execution_supported" => false, "requires_explicit_apply" => true)
end
