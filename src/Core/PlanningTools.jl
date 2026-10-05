# Only reviewed Core types are admitted. Plugin/MCP annotations and names do
# not establish read-only behavior; existing working-set filters still apply.
plan_tool_unrestricted(::AbstractTool)=false
plan_tool_unrestricted(::ReadTool)=true
plan_tool_unrestricted(::SearchTool)=true
plan_tool_unrestricted(::PlanTool)=true
plan_tool_actions(::AbstractTool)=()
plan_tool_actions(::MemoryTool)=("get","search","retrieve","list","status","namespaces","history","export")
plan_tool_actions(::ContextTool)=("status","source","artifact","instructions")
plan_tool_actions(::ModelsTool)=("status","list","inspect","count","health","routes","plan")
plan_tool_actions(::DiagnosticsTool)=("contracts","ambiguities","targets","compiler_source","evidence","evidence_source",
    "archive_source","archive_list","archive_get","archive_compare")
plan_tool_actions(::ProjectTool)=("status","search","impact","test_selection","architecture","migration","definitions","references",
    "hover","incoming_calls","outgoing_calls","implementations","diagnostics","julia_methods","julia_dispatch","julia_structure",
    "evidence_status","evidence_compare","evidence_search","evidence_impact","evidence_tests")
plan_tool_actions(::TaskTool)=("list","status","tasks","get")
plan_tool_actions(::TestingTool)=("discover","catalog","report","reports","source","history_list","history_get","history_source")

struct PlanningToolView{T<:AbstractTool} <: AbstractTool
    tool::T
    actions::Tuple
end
tool_name(value::PlanningToolView)=tool_name(value.tool)
tool_description(value::PlanningToolView)=tool_description(value.tool)*" Current plan mode permits only: "*join(value.actions,", ")*"."
execution_mode(value::PlanningToolView)=execution_mode(value.tool)
is_successful_tool_result(value::PlanningToolView,result)=is_successful_tool_result(value.tool,result)
tool_failure_message(value::PlanningToolView,result)=tool_failure_message(value.tool,result)
extra_context(value::PlanningToolView,session::Session,ctx::RuntimeContext)=extra_context(value.tool,session,ctx)
function tool_schema(value::PlanningToolView)
    schema=deepcopy(tool_schema(value.tool))
    actions=schema["properties"]["action"]["enum"]
    all(action->action in actions,value.actions) || throw(ShenScopeError(:extension,"Reviewed plan actions disagree with the Core tool schema"))
    schema["properties"]["action"]["enum"]=collect(value.actions)
    schema
end
function execute(value::PlanningToolView,arguments::AbstractDict,ctx::RuntimeContext)
    guard_agent_tool(value,arguments)
    execute(value.tool,arguments,ctx)
end

function guard_agent_tool(value::AbstractTool,arguments::AbstractDict)
    current_agent_mode()==AgentPlan || return
    underlying=value isa PlanningToolView ? value.tool : value
    plan_tool_unrestricted(underlying) && return
    actions=value isa PlanningToolView ? value.actions : plan_tool_actions(underlying)
    get(arguments,"action",nothing) in actions || throw(ShenScopeError(:agent_mode,"Tool action is unavailable in plan mode"))
    nothing
end

function plan_mode_toolset(tools::AbstractVector{<:AbstractTool})
    current_agent_mode()==AgentAct && return tools
    result=AbstractTool[]
    for value in tools
        if plan_tool_unrestricted(value)
            push!(result,value)
        elseif value isa PlanningToolView
            push!(result,value)
        else
            actions=plan_tool_actions(value)
            isempty(actions) || push!(result,PlanningToolView(value,actions))
        end
    end
    result
end
