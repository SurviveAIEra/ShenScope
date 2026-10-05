struct LanguageTool <: AbstractTool
    manager::LanguageServiceManager
    problems::ProblemManager
    operations::OperationManager
end

LanguageTool(problems=ProblemManager(); limits=LanguageServiceLimits()) = LanguageTool(
    LanguageServiceManager(; limits), problems,
    OperationManager(; event_prefix="language", max_running=4, max_result_bytes=4*1024^2,
        max_result_depth=40, max_result_nodes=200_000))
tool_name(::LanguageTool) = "language"
execution_mode(::LanguageTool) = :exclusive
tool_description(::LanguageTool) = "Explicitly start a configured stdio LSP language server for any supported project language, synchronize current disk documents, navigate verified locations and collect versioned diagnostics. Formatting/rename/code actions produce reviewable edits only. No automatic downloads, restart, command execution or workspace changes."

function tool_schema(::LanguageTool)
    object_schema(Dict(
        "action" => Dict("type" => "string", "enum" => vcat(["start", "stop", "status", "open", "close", "save", "diagnostics", "problems",
            "configure", "configured", "configuration", "remove_configuration", "start_configured", "incoming_calls", "outgoing_calls"], sort!(collect(keys(LSP_QUERY_METHODS))))),
        "server" => string_schema(; max=64), "name" => string_schema(; max=64),
        "argv" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => string_schema(; max=4096)),
        "languages" => Dict("type" => "array", "minItems" => 1, "maxItems" => 32, "items" => string_schema(; max=64)),
        "cwd" => string_schema(; max=4096), "initialization_options" => Dict("type" => "object"),
        "settings" => Dict("type" => "object"), "timeout" => Dict("type" => "number", "minimum" => 0.05, "maximum" => 120),
        "path" => string_schema(; max=4096), "language" => string_schema(; max=64),
        "expected_sha256" => string_schema(; max=64), "line" => integer_schema(0, 8*1024^2),
        "expected_version" => integer_schema(0),
        "character" => integer_schema(0, 8*1024^2), "limit" => integer_schema(1, 1000),
        "query" => string_schema(; max=2048), "new_name" => string_schema(; max=256),
        "include_declarations" => Dict("type" => "boolean"), "format_options" => Dict("type" => "object"),
        "mode" => Dict("type" => "string", "enum" => ["cached", "wait", "pull"])); required=["action"])
end

function execute(tool::LanguageTool, arguments::AbstractDict, ctx::RuntimeContext)
    validate_tool_arguments(tool, arguments)
    action = arguments["action"]
    if action in ("start", "configure")
        language_fields(arguments, ["action", "name", "argv", "languages"],
            vcat(["cwd", "initialization_options", "settings", "timeout"], action == "configure" ? ["expected_version"] : String[]), "language start action")
        spec = language_server_spec(Dict(key => value for (key, value) in arguments if !(key in ("action", "expected_version"))))
        action == "configure" && return save_language_configuration!(language_catalog_store(ctx), spec, ctx;
            expected_version=get(arguments,"expected_version",nothing))
        return start_language_service!(tool.manager, spec, ctx)
    elseif action == "configured"
        language_fields(arguments,["action"],String[],"saved language catalog action")
        return list_language_configurations(language_catalog_store(ctx),ctx)
    elseif action in ("configuration","remove_configuration","start_configured")
        language_fields(arguments,["action","server"], action == "configuration" ? ["expected_version"] : ["expected_version"],"saved language configuration action")
        store=language_catalog_store(ctx)
        action == "configuration" && return read_language_configuration(store,arguments["server"],ctx;
            expected_version=get(arguments,"expected_version",nothing))
        action == "remove_configuration" && return remove_language_configuration!(store,arguments["server"],ctx;
            expected_version=get(arguments,"expected_version",nothing))
        return start_configured_language_service!(tool.manager,store,arguments["server"],ctx;
            expected_version=get(arguments,"expected_version",nothing))
    elseif action == "status"
        language_fields(arguments, ["action"], ["server"], "language status action")
        return haskey(arguments, "server") ? language_client_status(owned_language_client(tool.manager, arguments["server"], ctx), ctx) :
            list_language_services(tool.manager, ctx)
    end
    name = language_text(get(arguments, "server", nothing), "language server name", 64)
    client = owned_language_client(tool.manager, name, ctx)
    if action == "stop"
        language_fields(arguments, ["action", "server"], String[], "language stop action")
        return stop_language_service!(tool.manager, name, ctx)
    elseif action in ("close", "save")
        language_fields(arguments, ["action", "server", "path"], String[], "language document action")
        return action == "close" ? close_language_document!(client, arguments["path"], ctx) :
            save_language_document!(client, arguments["path"], ctx)
    elseif action == "open"
        language_fields(arguments, ["action", "server", "path"], ["language", "expected_sha256"], "language open action")
        return synchronize_language_document!(client, arguments["path"], ctx;
            language=get(arguments, "language", nothing), expected_sha256=get(arguments, "expected_sha256", nothing))
    elseif action == "diagnostics"
        language_fields(arguments, ["action", "server", "path"], ["mode", "timeout"], "language diagnostic action")
        mode = get(arguments, "mode", "cached")
        if mode == "pull"
            return pull_language_diagnostics!(client, arguments["path"], ctx)
        elseif mode == "wait"
            return wait_language_diagnostics(client, arguments["path"], ctx; timeout=get(arguments, "timeout", 5.0))
        end
        _, path = workspace_snapshot_path(ctx, arguments["path"])
        language_client_access(client, ctx; process=false)
        authorize!(ctx, :read, "language", ctx.root; reason="Inspect retained language diagnostic status")
        return language_document_status(language_document(client, path))
    elseif action == "problems"
        language_fields(arguments, ["action", "server"], String[], "language problem capture")
        snapshot = capture_language_problems!(tool.problems, client, ctx)
        return Dict("snapshot_id" => snapshot.id, "snapshot_sha256" => snapshot.sha256,
            "provider" => snapshot.provider, "coverage" => deepcopy(snapshot.coverage))
    elseif action in ("incoming_calls","outgoing_calls")
        language_fields(arguments,["action","server","path"],["language","expected_sha256","line","character","limit"],"language call hierarchy action")
        return query_language_call_hierarchy(client,action,arguments,ctx)
    elseif haskey(LSP_QUERY_METHODS, action)
        allowed = action == "workspace_symbols" ? ["query", "limit"] :
            action == "document_symbols" ? ["language", "expected_sha256", "limit"] :
            action == "format" ? ["language", "expected_sha256", "format_options", "limit"] :
            vcat(["language", "expected_sha256", "line", "character", "limit"],
                action == "references" ? ["include_declarations"] : action == "rename" ? ["new_name"] : String[])
        required = action == "workspace_symbols" ? ["action", "server"] : ["action", "server", "path"]
        action == "rename" && push!(required, "new_name")
        language_fields(arguments, required, allowed, "language query action")
        return query_language_server(client, action, arguments, ctx)
    end
    throw(ShenScopeError(:language_config, "Unknown language service action"))
end
