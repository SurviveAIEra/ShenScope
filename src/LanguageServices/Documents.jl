const LANGUAGE_EXTENSION_IDS = Dict(
    ".py" => "python", ".pyi" => "python", ".go" => "go", ".rs" => "rust",
    ".js" => "javascript", ".mjs" => "javascript", ".cjs" => "javascript", ".jsx" => "javascriptreact",
    ".ts" => "typescript", ".mts" => "typescript", ".cts" => "typescript", ".tsx" => "typescriptreact",
    ".c" => "c", ".h" => "c", ".cpp" => "cpp", ".hpp" => "cpp", ".cc" => "cpp",
    ".java" => "java", ".jl" => "julia", ".rb" => "ruby", ".php" => "php",
    ".cs" => "csharp", ".sh" => "shellscript", ".json" => "json", ".html" => "html",
    ".css" => "css", ".vue" => "vue", ".lua" => "lua", ".swift" => "swift")

function language_document_id(client::LanguageClient, path::String, requested)
    language = requested === nothing ? get(LANGUAGE_EXTENSION_IDS, lowercase(splitext(path)[2]), nothing) : requested
    language = language_text(language, "document language ID", 64)
    language in client.spec.languages ||
        throw(ShenScopeError(:language_capability, "This language server was not configured for the document's language"))
    language
end

function language_document(client::LanguageClient, path::String)
    lock(client.mutex) do
        client.state == :ready || throw(ShenScopeError(:language_state, "Language server is not ready"))
        document = get(client.documents, path, nothing)
        document === nothing && throw(ShenScopeError(:language_document, "Synchronize this document with the language server first"))
        document
    end
end

function language_document_status(document::LanguageDocument)
    Dict("path" => document.snapshot.path, "source_sha256" => document.snapshot.sha256,
        "language" => document.language, "version" => document.version,
        "generation" => document.generation, "diagnostic_received" => document.diagnostic_received,
        "diagnostic_version" => document.diagnostic_version,
        "diagnostic_version_verified" => document.diagnostic_received && document.diagnostic_version == document.version,
        "retained_diagnostics" => length(document.diagnostic_items),
        "omitted_diagnostics" => document.diagnostic_omitted, "source" => "current_disk_snapshot")
end

function synchronize_language_document!(client::LanguageClient, path::AbstractString,
        ctx::RuntimeContext; language=nothing, expected_sha256=nothing)
    lock(client.document_mutex) do
        language_client_access(client, ctx)
        authorize!(ctx, :read, "language", ctx.root; reason="Synchronize a workspace file with the owning language server")
        snapshot = read_workspace_snapshot(ctx, path; expected_sha256,
            maximum_bytes=client.limits.maximum_document_bytes, tool="language.source", unicode_line_separators=false)
        id = language_document_id(client, snapshot.path, language)
        prior = lock(client.mutex) do
            client.state == :ready || throw(ShenScopeError(:language_state, "Language server is not ready"))
            get(client.documents, snapshot.path, nothing)
        end
        prior !== nothing && prior.language != id &&
            throw(ShenScopeError(:language_document, "Close the document before changing its language ID"))
        prior !== nothing && prior.snapshot.sha256 == snapshot.sha256 && return language_document_status(prior)
        capability = lock(client.mutex) do
            deepcopy(client.capabilities)
        end
        capability["open_close"] || throw(ShenScopeError(:language_capability, "Language server does not support owned document synchronization"))
        prior === nothing || capability["sync_kind"] != 0 ||
            throw(ShenScopeError(:language_capability, "Language server does not support source changes"))
        version = prior === nothing ? 1 : prior.version + 1
        version <= 2^31-1 || throw(ShenScopeError(:capacity, "Language document version is exhausted"))
        document = LanguageDocument(snapshot, id, version, client.generation, time(), ProjectProblem[],
            nothing, false, 0, 0)
        lock(client.mutex) do
            total = sum(ncodeunits(value.snapshot.source.source) for (key, value) in client.documents if key != snapshot.path; init=0)
            total + ncodeunits(snapshot.source.source) <= client.limits.maximum_document_total_bytes ||
                throw(ShenScopeError(:capacity, "Language server document memory capacity reached"))
            prior !== nothing || length(client.documents) < client.limits.maximum_documents ||
                throw(ShenScopeError(:capacity, "Language server document count capacity reached"))
            client.documents[snapshot.path] = document
        end
        uri = mcp_file_uri(snapshot.absolute)
        if prior === nothing
            language_notify!(client, "textDocument/didOpen", Dict("textDocument" => Dict(
                "uri" => uri, "languageId" => id, "version" => version, "text" => snapshot.source.source)), ctx)
        else
            change = Dict{String,Any}("text" => snapshot.source.source)
            if capability["sync_kind"] == 2
                old = prior.snapshot.source
                final_line = length(old.starts)
                final_column = old.ends[end] - old.starts[end] + 1
                whole = SourceRange(old.path, 1, final_line; start_column=1, end_column=final_column)
                change["range"] = source_editor_range(old, whole)
            end
            language_notify!(client, "textDocument/didChange", Dict("textDocument" => Dict(
                "uri" => uri, "version" => version), "contentChanges" => [change]), ctx)
        end
        verify_workspace_snapshot(snapshot, ctx; tool="language.source")
        language_document_status(document)
    end
end

function save_language_document!(client::LanguageClient, path::AbstractString, ctx::RuntimeContext)
    lock(client.document_mutex) do
        language_client_access(client, ctx)
        _, relative = workspace_snapshot_path(ctx, path)
        document = language_document(client, relative)
        verify_workspace_snapshot(document.snapshot, ctx; tool="language.source")
        capabilities = lock(client.mutex) do
            deepcopy(client.capabilities)
        end
        capabilities["save"] || return Dict("sent" => false, "reason" => "server_does_not_request_save")
        params = Dict{String,Any}("textDocument" => Dict("uri" => mcp_file_uri(document.snapshot.absolute)))
        capabilities["save_include_text"] && (params["text"] = document.snapshot.source.source)
        language_notify!(client, "textDocument/didSave", params, ctx)
        Dict("sent" => true, "path" => relative, "version" => document.version)
    end
end

function close_language_document!(client::LanguageClient, path::AbstractString, ctx::RuntimeContext)
    lock(client.document_mutex) do
        language_client_access(client, ctx)
        absolute, relative = workspace_snapshot_path(ctx, path; must_exist=false)
        authorize!(ctx, :read, "language", ctx.root; reason="Close an owned language-service document")
        removed = lock(client.mutex) do
            pop!(client.documents, relative, nothing)
        end
        removed === nothing && return Dict("closed" => false, "path" => relative)
        language_notify!(client, "textDocument/didClose", Dict("textDocument" => Dict("uri" => mcp_file_uri(absolute))), ctx)
        Dict("closed" => true, "path" => relative)
    end
end
