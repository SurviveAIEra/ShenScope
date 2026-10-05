function language_query_parameters(action::String, document::Union{Nothing,LanguageDocument}, arguments)
    action == "workspace_symbols" && return Dict("query" => language_text(get(arguments, "query", ""), "symbol search", 2048; empty=true))
    document === nothing && throw(ShenScopeError(:language_document, "Language query requires a synchronized source"))
    params = Dict{String,Any}("textDocument" => Dict("uri" => mcp_file_uri(document.snapshot.absolute)))
    if action in ("definitions", "references", "hover", "implementations", "type_definitions", "rename", "code_actions", "completions", "signature_help")
        params["position"] = language_cursor(document.snapshot.source,
            get(arguments, "line", 0), get(arguments, "character", 0))
    end
    if action == "references"
        declaration = get(arguments, "include_declarations", true)
        declaration isa Bool || throw(ShenScopeError(:language_config, "Invalid reference declaration option"))
        params["context"] = Dict("includeDeclaration" => declaration)
    elseif action == "completions"
        params["context"] = Dict("triggerKind" => 1)
    elseif action == "signature_help"
        params["context"] = Dict("triggerKind" => 1, "isRetrigger" => false)
    elseif action == "rename"
        params["newName"] = language_text(get(arguments, "new_name", nothing), "new symbol name", 256)
    elseif action == "format"
        options = get(arguments, "format_options", Dict("tabSize" => 4, "insertSpaces" => true))
        options isa AbstractDict && haskey(options, "tabSize") && get(options, "insertSpaces", nothing) isa Bool ||
            throw(ShenScopeError(:language_config, "Formatting requires tabSize and insertSpaces"))
        language_integer(options["tabSize"], "format tab size", 1, 16)
        bounded_canonical_json(options; maximum=4096, max_depth=8, max_nodes=256)
        params["options"] = deepcopy(options)
    elseif action == "code_actions"
        position = pop!(params, "position")
        params["range"] = Dict("start" => position, "end" => position)
        params["context"] = Dict("diagnostics" => Any[], "triggerKind" => 1)
    end
    params
end

function query_language_server(client::LanguageClient, action::String, arguments::AbstractDict,
        ctx::RuntimeContext)
    haskey(LSP_QUERY_METHODS, action) || throw(ShenScopeError(:language_config, "Unknown language navigation action"))
    lock(client.document_mutex) do
        language_client_access(client, ctx)
        authorize!(ctx, :read, "language", ctx.root; reason="Query the explicitly started project language server")
        language_require_capability(client, action)
        maximum = language_integer(get(arguments, "limit", 100), "language result limit", 1, client.limits.maximum_result_items)
        document = nothing
        if action != "workspace_symbols"
            path = language_text(get(arguments, "path", nothing), "language query file", 4096)
            synchronize_language_document!(client, path, ctx; language=get(arguments, "language", nothing),
                expected_sha256=get(arguments, "expected_sha256", nothing))
            _, relative = workspace_snapshot_path(ctx, path)
            document = language_document(client, relative)
        end
        params = language_query_parameters(action, document, arguments)
        response = language_request!(client, LSP_QUERY_METHODS[action], params, ctx)
        primary = document === nothing ? nothing : document.snapshot
        primary === nothing || verify_workspace_snapshot(primary, ctx; tool="language.source")
        sources = LanguageResultSources(ctx; primary)
        result = if action in ("definitions", "references", "implementations", "type_definitions")
            normalize_language_locations(response, sources; maximum, origin=primary)
        elseif action == "hover"
            normalize_language_hover(response, primary)
        elseif action == "completions"
            normalize_language_completions(response, primary; maximum)
        elseif action == "signature_help"
            normalize_language_signature_help(response; maximum=min(maximum,32))
        elseif action in ("document_symbols", "workspace_symbols")
            normalize_language_symbols(response, sources; primary, maximum)
        elseif action == "format"
            language_format_edit(response, primary)
        elseif action == "rename"
            language_workspace_edit(response, client, ctx; sources)
        else
            normalize_language_code_actions(response, client, ctx; maximum, sources)
        end
        versions = verify_language_result_sources!(sources)
        language_client_access(client, ctx)
        merge!(result, Dict("server" => client.spec.name, "action" => action,
            "configuration_sha256" => client.spec.fingerprint,
            "document_version" => document === nothing ? nothing : document.version,
            "source_versions" => versions, "source_versions_verified" => true,
            "source_check_scope" => "observed_projection_sources_before_publication",
            "whole_server_dependency_snapshot_verified" => false,
            "complete_project_coverage" => false, "automatic_execution" => false))
        bounded_canonical_json(result; maximum=3*1024^2, max_depth=32, max_nodes=100_000)
        result
    end
end
