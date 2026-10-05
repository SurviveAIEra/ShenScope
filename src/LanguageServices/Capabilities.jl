function language_client_capabilities()
    Dict("general" => Dict("positionEncodings" => ["utf-16"]),
        "workspace" => Dict("configuration" => true, "workspaceFolders" => true,
            "applyEdit" => false, "workspaceEdit" => Dict("documentChanges" => true,
                "resourceOperations" => String[], "failureHandling" => "abort"),
            "symbol" => Dict("dynamicRegistration" => false)),
        "textDocument" => Dict(
            "synchronization" => Dict("dynamicRegistration" => false, "willSave" => false, "didSave" => true),
            "publishDiagnostics" => Dict("versionSupport" => true,
                "tagSupport" => Dict("valueSet" => [1,2]), "relatedInformation" => false),
            "hover" => Dict("dynamicRegistration" => false, "contentFormat" => ["plaintext", "markdown"]),
            "definition" => Dict("dynamicRegistration" => false, "linkSupport" => true),
            "typeDefinition" => Dict("dynamicRegistration" => false, "linkSupport" => true),
            "implementation" => Dict("dynamicRegistration" => false, "linkSupport" => true),
            "references" => Dict("dynamicRegistration" => false),
            "completion" => Dict("dynamicRegistration" => false, "completionItem" => Dict(
                "snippetSupport" => false, "insertReplaceSupport" => true, "documentationFormat" => ["plaintext", "markdown"])),
            "signatureHelp" => Dict("dynamicRegistration" => false, "signatureInformation" => Dict(
                "documentationFormat" => ["plaintext", "markdown"], "parameterInformation" => Dict("labelOffsetSupport" => true))),
            "callHierarchy" => Dict("dynamicRegistration" => false),
            "documentSymbol" => Dict("dynamicRegistration" => false, "hierarchicalDocumentSymbolSupport" => true),
            "rename" => Dict("dynamicRegistration" => false, "prepareSupport" => false),
            "formatting" => Dict("dynamicRegistration" => false),
            "codeAction" => Dict("dynamicRegistration" => false,
                "codeActionLiteralSupport" => Dict("codeActionKind" => Dict("valueSet" => ["quickfix", "refactor", "source"]))),
            "diagnostic" => Dict("dynamicRegistration" => false, "relatedDocumentSupport" => false)))
end

function language_server_capabilities(result)
    result isa AbstractDict && get(result, "capabilities", nothing) isa AbstractDict ||
        throw(ShenScopeError(:language_protocol, "Language initialization has no capabilities object"))
    supplied = result["capabilities"]
    bounded_canonical_json(supplied; maximum=512*1024, max_depth=24, max_nodes=32_000)
    encoding = get(supplied, "positionEncoding", "utf-16")
    encoding == "utf-16" || throw(ShenScopeError(:language_capability, "Language server did not negotiate UTF-16 positions"))
    normalized = Dict{String,Any}("position_encoding" => "utf16")
    sync = get(supplied, "textDocumentSync", 0)
    if sync isa Integer && !(sync isa Bool)
        normalized["sync_kind"] = language_integer(sync, "document synchronization kind", 0, 2)
        normalized["open_close"] = sync != 0
        normalized["save"] = false
        normalized["save_include_text"] = false
    elseif sync isa AbstractDict
        normalized["sync_kind"] = language_integer(get(sync, "change", 0), "document synchronization kind", 0, 2)
        open_close = get(sync, "openClose", false)
        open_close isa Bool || throw(ShenScopeError(:language_protocol, "Invalid open/close capability"))
        normalized["open_close"] = open_close
        save = get(sync, "save", false)
        save isa Bool || save isa AbstractDict || throw(ShenScopeError(:language_protocol, "Invalid save capability"))
        include_text = save isa AbstractDict ? get(save, "includeText", false) : false
        include_text isa Bool || throw(ShenScopeError(:language_protocol, "Invalid save text capability"))
        normalized["save"] = save isa AbstractDict || save === true
        normalized["save_include_text"] = include_text
    else
        throw(ShenScopeError(:language_protocol, "Invalid document synchronization capability"))
    end
    mappings = Dict("definitions" => "definitionProvider", "references" => "referencesProvider",
        "hover" => "hoverProvider", "implementations" => "implementationProvider",
        "type_definitions" => "typeDefinitionProvider", "document_symbols" => "documentSymbolProvider",
        "workspace_symbols" => "workspaceSymbolProvider", "format" => "documentFormattingProvider",
        "rename" => "renameProvider", "code_actions" => "codeActionProvider", "pull_diagnostics" => "diagnosticProvider",
        "completions" => "completionProvider", "signature_help" => "signatureHelpProvider", "call_hierarchy" => "callHierarchyProvider")
    for (action, key) in mappings
        value = get(supplied, key, false)
        value === nothing && (value = false)
        value isa Bool || value isa AbstractDict || throw(ShenScopeError(:language_protocol, "Invalid language capability: " * key))
        normalized[action] = value === true || value isa AbstractDict
    end
    normalized
end

function language_require_capability(client::LanguageClient, action::String)
    lock(client.mutex) do
        client.state == :ready || throw(ShenScopeError(:language_state, "Language server is not ready"))
        get(client.capabilities, action, false) === true ||
            throw(ShenScopeError(:language_capability, "Language server does not advertise " * action))
    end
    nothing
end
