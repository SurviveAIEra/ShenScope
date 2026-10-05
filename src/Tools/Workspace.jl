struct WorkspaceTool <: AbstractTool
    manager::WorkspaceEditManager
    testing::ProjectTestManager
    operations::OperationManager
end

WorkspaceTool(testing=ProjectTestManager(); limits=WorkspaceEditLimits()) = WorkspaceTool(
    WorkspaceEditManager(; limits), testing,
    OperationManager(; event_prefix="workspace", max_running=2, max_result_bytes=4*1024^2,
        max_result_depth=32, max_result_nodes=200_000))
tool_name(::WorkspaceTool) = "workspace"
execution_mode(::WorkspaceTool) = :exclusive
tool_description(::WorkspaceTool) = "Prepare, preview and explicitly apply hash-guarded multi-file source edits. Reject overlapping/stale ranges, share file locks with ordinary edits, retain application receipts, and avoid overwriting external changes during rollback. Explicitly verify an applied proposal with selected project test commands. No automatic replay or complete-project coverage claim."

function tool_schema(::WorkspaceTool)
    position = object_schema(Dict("file" => string_schema(; max=4096), "start_line" => integer_schema(1),
        "end_line" => integer_schema(1), "start_column" => integer_schema(1), "end_column" => integer_schema(1),
        "column_unit" => Dict("type" => "string", "enum" => ["utf8_byte"]));
        required=["file", "start_line", "end_line"])
    edit = object_schema(Dict("location" => position, "new_text" => string_schema(; max=4*1024^2)))
    file = object_schema(Dict("path" => string_schema(; max=4096), "expected_sha256" => string_schema(; max=64),
        "line_break_policy" => Dict("type" => "string", "enum" => ["unicode_source", "lsp_cr_lf"]),
        "edits" => Dict("type" => "array", "minItems" => 1, "maxItems" => 2048, "items" => edit));
        required=["path", "expected_sha256", "edits"])
    object_schema(Dict("action" => Dict("type" => "string", "enum" => ["prepare", "list", "get", "preview", "source", "discard", "apply", "verify",
            "history_save", "history_list", "history_get", "history_sources", "history_restore", "history_delete"]),
        "files" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => file),
        "title" => string_schema(; max=1024), "origin" => string_schema(; max=256),
        "plan_id" => string_schema(; max=128), "expected_plan_sha256" => string_schema(; max=64),
        "history_id" => string_schema(; max=128), "expected_version" => integer_schema(0),
        "expected_record_sha256" => string_schema(; max=64),
        "path" => string_schema(; max=4096), "side" => Dict("type" => "string", "enum" => ["before", "after"]),
        "context_lines" => integer_schema(0, 20), "include_text" => Dict("type" => "boolean"),
        "catalog_id" => string_schema(; max=128), "candidate_ids" => Dict("type" => "array", "minItems" => 1,
            "maxItems" => 16, "items" => string_schema(; max=64)),
        "timeout" => Dict("type" => "number", "minimum" => 0.05, "maximum" => 3600),
        "stop_on_failure" => Dict("type" => "boolean")); required=["action"])
end

function execute(tool::WorkspaceTool, arguments::AbstractDict, ctx::RuntimeContext)
    validate_tool_arguments(tool, arguments)
    action = arguments["action"]
    if action == "prepare"
        workspace_edit_fields(arguments, ["action", "files"], ["title", "origin"], "workspace preparation action")
        return prepare_workspace_edits!(tool.manager, ctx, arguments["files"];
            title=get(arguments, "title", "Workspace changes"), origin=get(arguments, "origin", "explicit_proposal"))
    elseif action == "list"
        workspace_edit_fields(arguments, ["action"], String[], "workspace list action")
        return list_workspace_edit_plans(tool.manager, ctx)
    elseif action == "get"
        workspace_edit_fields(arguments, ["action", "plan_id"], String[], "workspace plan read")
        return read_workspace_edit_plan(tool.manager, arguments["plan_id"], ctx)
    elseif action == "preview"
        workspace_edit_fields(arguments, ["action", "plan_id"], ["context_lines", "include_text"], "workspace preview action")
        return preview_workspace_edits(tool.manager, arguments["plan_id"], ctx;
            context_lines=get(arguments, "context_lines", 3), include_text=get(arguments, "include_text", false))
    elseif action == "source"
        workspace_edit_fields(arguments, ["action", "plan_id", "path"], ["side"], "workspace source action")
        return read_workspace_edit_source(tool.manager, arguments["plan_id"], arguments["path"], ctx; side=get(arguments, "side", "after"))
    elseif action in ("discard", "apply")
        workspace_edit_fields(arguments, ["action", "plan_id", "expected_plan_sha256"], String[], "workspace edit controller")
        return action == "apply" ? apply_workspace_edits!(tool.manager, arguments["plan_id"], ctx;
            expected_plan_sha256=arguments["expected_plan_sha256"]) :
            discard_workspace_edit_plan!(tool.manager, arguments["plan_id"], ctx; expected_plan_sha256=arguments["expected_plan_sha256"])
    elseif action == "verify"
        workspace_edit_fields(arguments, ["action", "plan_id", "expected_plan_sha256", "catalog_id", "candidate_ids"],
            ["timeout", "stop_on_failure"], "workspace verification action")
        return verify_workspace_edits!(tool.manager, tool.testing, arguments["plan_id"], ctx;
            expected_plan_sha256=arguments["expected_plan_sha256"], catalog_id=arguments["catalog_id"],
            candidate_ids=arguments["candidate_ids"], timeout=get(arguments, "timeout", 120.0),
            stop_on_failure=get(arguments, "stop_on_failure", false))
    elseif action == "history_save"
        workspace_edit_fields(arguments, ["action", "plan_id", "expected_plan_sha256", "expected_version"],
            String[], "workspace history save")
        return save_workspace_history!(workspace_history_store(ctx), tool.manager, arguments["plan_id"], ctx;
            expected_plan_sha256=arguments["expected_plan_sha256"], expected_version=arguments["expected_version"])
    elseif action == "history_list"
        workspace_edit_fields(arguments, ["action"], String[], "workspace history list")
        return list_workspace_history(workspace_history_store(ctx), ctx)
    elseif action in ("history_get", "history_sources", "history_delete", "history_restore")
        required = ["action", "history_id", "expected_version"]
        action == "history_restore" && push!(required, "expected_record_sha256")
        workspace_edit_fields(arguments, required, String[], "workspace history controller")
        store = workspace_history_store(ctx)
        id = arguments["history_id"]
        version = arguments["expected_version"]
        action == "history_get" && return read_workspace_history(store, id, ctx; expected_version=version)
        action == "history_sources" && return inspect_workspace_history_sources(store, id, ctx; expected_version=version)
        action == "history_delete" && return remove_workspace_history!(store, id, ctx; expected_version=version)
        return restore_workspace_proposal!(store, tool.manager, id, ctx; expected_version=version,
            expected_record_sha256=arguments["expected_record_sha256"])
    end
    throw(ShenScopeError(:workspace_edit, "Unknown workspace edit action"))
end

function is_successful_tool_result(::WorkspaceTool, value)
    outcome = get(value, "outcome", nothing)
    outcome === nothing || outcome in ("applied", "command_succeeded")
end

function tool_failure_message(::WorkspaceTool, value)
    outcome = get(value, "outcome", nothing)
    outcome === nothing || outcome in ("applied", "command_succeeded") ? nothing :
        "Workspace operation did not confirm success: " * string(outcome)
end
