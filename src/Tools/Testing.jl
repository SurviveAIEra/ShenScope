struct TestingTool <: AbstractTool
    manager::ProjectTestManager
    operations::OperationManager
end
TestingTool()=TestingTool(ProjectTestManager(),OperationManager(;event_prefix="testing",max_running=2))
tool_name(::TestingTool)="testing"
tool_description(::TestingTool)="Discover project test commands without executing them; explicitly run a selected hash-checked candidate or argument-vector command in any language. Retain exit/timeout/cancel evidence, framework-reported cases and untrusted source references. A successful command is not proof of complete coverage."
execution_mode(::TestingTool)=:exclusive
is_successful_tool_result(::TestingTool,value)=!(value isa AbstractDict && haskey(value,"outcome")) || value["outcome"]=="command_succeeded"
tool_failure_message(tool::TestingTool,value)=is_successful_tool_result(tool,value) ? nothing : "Captured test execution outcome: "*String(value["outcome"])*". The execution receipt was retained; no automatic replay."

function tool_schema(::TestingTool)
    limits=object_schema(Dict(String(field)=>integer_schema(field==:depth ? 0 : field in (:marker_bytes,:total_marker_bytes) ? 64 : 1)
        for field in fieldnames(ProjectTestDiscoveryLimits));required=String[])
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["discover","catalog","run","custom","report","reports","source"]),
        "scopes"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>16,"items"=>string_schema(;max=4096)),"limits"=>limits,
        "catalog_id"=>string_schema(;max=64),"candidate_id"=>string_schema(;max=64),"run_id"=>string_schema(;max=128),
        "frame_id"=>string_schema(;max=64),"argv"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>128,"items"=>string_schema(;max=8192)),
        "cwd"=>string_schema(;max=4096),"framework"=>Dict("type"=>"string","enum"=>collect(PROJECT_TEST_FRAMEWORKS)),
        "label"=>string_schema(;max=512),"timeout"=>Dict("type"=>"number","minimum"=>0.05,"maximum"=>3600),
        "output_limit"=>integer_schema(64,1024^2),"limit"=>integer_schema(1,32),"context_lines"=>integer_schema(0,20),
        "expected_sha256"=>string_schema(;max=64));required=["action"])
end

function project_test_action_fields(arguments,required,optional)
    allowed=Set(vcat(["action"],required,optional))
    all(key->key in allowed,keys(arguments)) && all(key->haskey(arguments,key),required) ||
        throw(ShenScopeError(:testing,"Invalid fields for this project test action"))
    nothing
end

function execute(tool::TestingTool,arguments::AbstractDict,ctx::RuntimeContext)
    validate_tool_arguments(tool,arguments);action=arguments["action"]
    action=="discover" && begin
        project_test_action_fields(arguments,String[],["scopes","limits"])
        settings=get(arguments,"limits",Dict())
        limits=ProjectTestDiscoveryLimits(;Dict(Symbol(key)=>value for (key,value) in settings)...)
        return discover_project_tests!(tool.manager,ctx;scopes=get(arguments,"scopes",["."]),limits)
    end
    if action=="catalog"
        project_test_action_fields(arguments,["catalog_id"],String[])
        return read_project_test_catalog(tool.manager,arguments["catalog_id"],ctx)
    elseif action=="run"
        project_test_action_fields(arguments,["catalog_id","candidate_id"],["timeout","output_limit"])
        return run_project_tests!(tool.manager,ctx;catalog_id=arguments["catalog_id"],candidate_id=arguments["candidate_id"],
            timeout=get(arguments,"timeout",120.0),output_limit=get(arguments,"output_limit",256*1024))
    elseif action=="custom"
        project_test_action_fields(arguments,["argv"],["cwd","framework","label","timeout","output_limit"])
        return run_project_test_command!(tool.manager,ctx;argv=arguments["argv"],cwd=get(arguments,"cwd","."),
            framework=get(arguments,"framework","raw"),label=get(arguments,"label","Explicit test command"),
            timeout=get(arguments,"timeout",120.0),output_limit=get(arguments,"output_limit",256*1024))
    elseif action=="report"
        project_test_action_fields(arguments,["run_id"],String[])
        return read_project_test_report(tool.manager,arguments["run_id"],ctx)
    elseif action=="reports"
        project_test_action_fields(arguments,String[],["limit"])
        return list_project_test_reports(tool.manager,ctx;limit=get(arguments,"limit",16))
    elseif action=="source"
        project_test_action_fields(arguments,["run_id","frame_id"],["context_lines","expected_sha256"])
        return read_project_test_source(tool.manager,arguments["run_id"],arguments["frame_id"],ctx;
            context_lines=get(arguments,"context_lines",3),expected_sha256=get(arguments,"expected_sha256",nothing))
    end
    throw(ShenScopeError(:testing,"Unknown project test action"))
end
