const AGENT_PLAN_SCHEMA="shenscope.conversation-plan/1"
const AGENT_PLAN_MAX_BYTES=96*1024
const AGENT_PLAN_MAX_STEPS=64
const AGENT_PLAN_STATUSES=("pending","in_progress","completed","blocked","skipped")
const AGENT_PLAN_LIMITATIONS=["Plans and step progress are reported intent, not automatic execution or proof of completion.",
    "Message citations verify owning conversation bytes; they do not establish truth or successful testing.",
    "The user controls execution mode; a plan cannot relax permission policy."]

struct AgentPlanCitation
    message::Int
    sha256::String
end
struct AgentPlanStep
    id::String
    text::String
    status::String
    dependencies::Vector{String}
    note::String
    citations::Vector{AgentPlanCitation}
end
struct AgentPlanDocument
    revision::Int
    title::String
    steps::Vector{AgentPlanStep}
    created_at::String
    updated_at::String
    owner::String
    root_sha256::String
    parent_plan_sha256::Union{Nothing,String}
    sha256::String
end
mutable struct AgentPlanManager
    sessions::Dict{Tuple{String,String},WeakRef}
    mutex::ReentrantLock
end
AgentPlanManager()=AgentPlanManager(Dict{Tuple{String,String},WeakRef}(),ReentrantLock())

agent_plan_citation_view(value::AgentPlanCitation)=Dict("message"=>value.message,"sha256"=>value.sha256)
agent_plan_step_view(value::AgentPlanStep)=Dict("id"=>value.id,"text"=>value.text,"status"=>value.status,
    "dependencies"=>copy(value.dependencies),"note"=>value.note,"citations"=>agent_plan_citation_view.(value.citations))
function agent_plan_body(value::AgentPlanDocument)
    Dict("schema"=>AGENT_PLAN_SCHEMA,"revision"=>value.revision,"title"=>value.title,
        "steps"=>agent_plan_step_view.(value.steps),"created_at"=>value.created_at,"updated_at"=>value.updated_at,
        "session_id"=>value.owner,"root_sha256"=>value.root_sha256,"parent_plan_sha256"=>value.parent_plan_sha256)
end
agent_plan_document_view(value::AgentPlanDocument)=merge(agent_plan_body(value),Dict("sha256"=>value.sha256))

function agent_plan_summary(value::AgentPlanDocument)
    Dict("steps"=>length(value.steps),"statuses"=>Dict(status=>count(step->step.status==status,value.steps) for status in AGENT_PLAN_STATUSES),
        "dependencies"=>sum(length(step.dependencies) for step in value.steps;init=0),
        "citations"=>sum(length(step.citations) for step in value.steps;init=0),
        "progress_independently_verified"=>false,"automatic_execution"=>false)
end
