@enum AgentExecutionMode AgentAct AgentPlan
const AGENT_EXECUTION_MODE=ScopedValue(AgentAct)
const AGENT_PLAN_DENIED_CATEGORIES=(:edit,:process,:dynamic,:mcp)
const AGENT_PLAN_STATE_WRITERS=("context.archive","context.compact","agent.plan")
const AGENT_MODE_SCHEMA="shenscope.agent-mode/1"

function parse_agent_mode(value)
    value isa AgentExecutionMode && return value
    value isa AbstractString || throw(ShenScopeError(:agent_mode,"Agent mode must be act or plan"))
    value=="act" && return AgentAct
    value=="plan" && return AgentPlan
    throw(ShenScopeError(:agent_mode,"Agent mode must be act or plan"))
end
agent_mode_name(mode::AgentExecutionMode)=mode==AgentPlan ? "plan" : "act"
current_agent_mode()=AGENT_EXECUTION_MODE[]

function with_agent_execution_mode(f::Function,requested)
    selected=parse_agent_mode(requested)
    effective=current_agent_mode()==AgentPlan ? AgentPlan : selected
    with(f,AGENT_EXECUTION_MODE=>effective)
end

function agent_mode_authorize(category::Symbol,tool::AbstractString)
    if current_agent_mode()==AgentPlan
        (category in AGENT_PLAN_DENIED_CATEGORIES || category==:persistence && !(tool in AGENT_PLAN_STATE_WRITERS)) &&
            throw(ShenScopeError(:agent_mode,"Operation is unavailable in plan mode"))
    end
    nothing
end

function agent_control_fields(value,fields,label)
    value isa AbstractDict && Set(keys(value))==Set(fields) ||
        throw(ShenScopeError(:agent_plan,"Invalid "*label*" fields"))
    value
end
function agent_control_integer(value,label,first,last)
    value isa Integer && !(value isa Bool) && first<=value<=last ||
        throw(ShenScopeError(:agent_plan,"Invalid "*label))
    Int(value)
end
function agent_control_text(value,label,maximum;empty=false)
    value isa String && isvalid(value) && ncodeunits(value)<=maximum && !occursin('\0',value) &&
        (empty || !isempty(strip(value))) || throw(ShenScopeError(:agent_plan,"Invalid "*label))
    value
end
function agent_control_hash(value,label)
    value isa String && occursin(r"^[0-9a-f]{64}$",value) || throw(ShenScopeError(:agent_plan,"Invalid "*label))
    value
end

function agent_mode_instructions()
    current_agent_mode()==AgentPlan || return ""
    "The user selected plan mode. Inspect available read-only evidence and maintain a reviewable conversation plan. "*
    "Do not edit workspace files, execute commands, load dynamic code or invoke MCP operations. "*
    "Only the user can change execution mode. Plan progress and cited observations are reported evidence, not automatic execution or proof of completion. "*
    "Existing read and model-network permissions still apply."
end
