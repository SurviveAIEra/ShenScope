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
tool_description(::ValidationTool) = "Explicitly run a compiler, linter or other project check using an argument vector, bind selected source hashes and interpret bounded output into owned Problems. Available output families include GCC, TypeScript, Python and Go. A successful command does not establish complete project coverage."

function tool_schema(::ValidationTool)
    object_schema(Dict("action" => Dict("type" => "string", "enum" => ["run", "get", "list"]),
        "argv" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => string_schema(; max=4096)),
        "paths" => Dict("type" => "array", "minItems" => 1, "maxItems" => 64, "items" => string_schema(; max=4096)),
        "cwd" => string_schema(; max=4096), "family" => Dict("type" => "string", "enum" => collect(VALIDATION_FAMILIES)),
        "column_unit" => Dict("type" => "string", "enum" => ["unknown", "utf8_byte", "utf16", "unicode_scalar"]),
        "label" => string_schema(; max=512), "timeout" => Dict("type" => "number", "minimum" => 0.05, "maximum" => 3600),
        "validation_id" => string_schema(; max=128)); required=["action"])
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
    elseif action == "get"
        workspace_edit_fields(arguments,["action","validation_id"],String[],"validation receipt read")
        return read_validation_report(tool.manager,arguments["validation_id"],ctx)
    elseif action == "list"
        workspace_edit_fields(arguments,["action"],String[],"validation history read")
        return list_validation_reports(tool.manager,ctx)
    end
    throw(ShenScopeError(:validation,"Unknown project validation action"))
end

is_successful_tool_result(::ValidationTool,value) = !haskey(value,"outcome") || value["outcome"] == "command_succeeded"
tool_failure_message(tool::ValidationTool,value) = is_successful_tool_result(tool,value) ? nothing : "Project check did not succeed: " * value["outcome"]
