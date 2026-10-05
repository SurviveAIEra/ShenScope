struct ValidationTool <: AbstractTool
    manager::ProjectValidationManager
    operations::OperationManager
end

ValidationTool(testing::ProjectTestManager=ProjectTestManager(), problems::ProblemManager=ProblemManager(); limits=ValidationLimits()) =
    ValidationTool(ProjectValidationManager(testing, problems; limits),
        OperationManager(; event_prefix="validation", max_running=2, max_result_bytes=3*1024^2,
            max_result_depth=32, max_result_nodes=100_000))
tool_name(::ValidationTool) = "validation"
execution_mode(::ValidationTool) = :exclusive
tool_description(::ValidationTool) = "Explicitly run a compiler, linter or project check using an argument vector; alternatively import SARIF 2.1.0 with explicit report/source hashes. Retain source-associated Problems. Imported reports are untrusted caller-bound evidence, without executing fixes. Command success does not establish complete project coverage."

function tool_schema(::ValidationTool)
    version = object_schema(Dict("path" => string_schema(; max=4096), "expected_sha256" => string_schema(; max=64)))
    object_schema(Dict("action" => Dict("type" => "string", "enum" => ["run", "import_sarif", "get", "list", "sources", "compare"]),
        "argv" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => string_schema(; max=4096)),
        "paths" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => string_schema(; max=4096)),
        "cwd" => string_schema(; max=4096), "family" => Dict("type" => "string", "enum" => collect(VALIDATION_FAMILIES)),
        "column_unit" => Dict("type" => "string", "enum" => ["unknown", "utf8_byte", "utf16", "unicode_scalar"]),
        "label" => string_schema(; max=512), "timeout" => Dict("type" => "number", "minimum" => 0.05, "maximum" => 3600),
        "path" => string_schema(; max=4096), "expected_report_sha256" => string_schema(; max=64),
        "source_versions" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => version),
        "validation_id" => string_schema(; max=128), "before_id" => string_schema(; max=128),
        "after_id" => string_schema(; max=128), "limit" => integer_schema(1, 1000)); required=["action"])
end

function execute(tool::ValidationTool, arguments::AbstractDict, ctx::RuntimeContext)
    validate_tool_arguments(tool, arguments)
    action = arguments["action"]
    if action == "run"
        workspace_edit_fields(arguments, ["action", "argv", "paths"],
            ["cwd", "family", "column_unit", "label", "timeout"], "validation command action")
        return run_project_validation!(tool.manager, ctx; argv=arguments["argv"], paths=arguments["paths"],
            cwd=get(arguments,"cwd","."), family=get(arguments,"family","generic"),
            column_unit=get(arguments,"column_unit","unknown"), label=get(arguments,"label","Explicit project check"),
            timeout=get(arguments,"timeout",120.0))
    elseif action == "import_sarif"
        workspace_edit_fields(arguments, ["action", "path", "expected_report_sha256", "source_versions"],
            ["label"], "SARIF import action")
        return import_sarif_report!(tool.manager, ctx; path=arguments["path"],
            expected_report_sha256=arguments["expected_report_sha256"], source_versions=arguments["source_versions"],
            label=get(arguments, "label", "Imported SARIF report"))
    elseif action == "compare"
        workspace_edit_fields(arguments, ["action", "before_id", "after_id"], ["limit"], "validation comparison")
        return compare_project_validation_reports(tool.manager, arguments["before_id"], arguments["after_id"], ctx;
            limit=get(arguments, "limit", 256))
    elseif action == "sources"
        workspace_edit_fields(arguments, ["action", "validation_id"], String[], "validation source inspection")
        return inspect_validation_sources(tool.manager, arguments["validation_id"], ctx)
    elseif action == "get"
        workspace_edit_fields(arguments,["action","validation_id"],String[],"validation receipt read")
        return read_validation_report(tool.manager,arguments["validation_id"],ctx)
    elseif action == "list"
        workspace_edit_fields(arguments,["action"],String[],"validation history read")
        return list_validation_reports(tool.manager,ctx)
    end
    throw(ShenScopeError(:validation,"Unknown project validation action"))
end

is_successful_tool_result(::ValidationTool,value) = !haskey(value,"outcome") || value["outcome"] in ("command_succeeded", "report_imported")
tool_failure_message(tool::ValidationTool,value) = is_successful_tool_result(tool,value) ? nothing : "Project check did not succeed: " * value["outcome"]
