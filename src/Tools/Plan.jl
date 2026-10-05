struct PlanTool <: AbstractTool
    manager::AgentPlanManager
end
PlanTool()=PlanTool(AgentPlanManager())
tool_name(::PlanTool)="plan"
tool_description(::PlanTool)="Read, replace or report progress on a version-checked conversation plan. Step dependencies and owned message hashes are checked. Progress remains reported intent, not execution proof. This tool cannot change agent mode."
execution_mode(::PlanTool)=:exclusive

function tool_schema(::PlanTool)
    citation=object_schema(Dict("message"=>integer_schema(1),"sha256"=>string_schema(;max=64)))
    citations=Dict("type"=>"array","maxItems"=>8,"items"=>citation)
    status=Dict("type"=>"string","enum"=>collect(AGENT_PLAN_STATUSES))
    step=object_schema(Dict("id"=>string_schema(;max=64),"text"=>string_schema(;max=1024),"status"=>status,
        "dependencies"=>Dict("type"=>"array","maxItems"=>16,"items"=>string_schema(;max=64)),
        "note"=>string_schema(;max=2048),"citations"=>citations))
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["get","replace","progress","history"]),
        "title"=>string_schema(;max=512),"steps"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>AGENT_PLAN_MAX_STEPS,"items"=>step),
        "expected_revision"=>integer_schema(0,999_999),"id"=>string_schema(;max=64),"status"=>status,
        "note"=>string_schema(;max=2048),"citations"=>citations,"limit"=>integer_schema(1,16));required=["action"])
end

function execute(tool::PlanTool,arguments::AbstractDict,ctx::RuntimeContext)
    validate_tool_arguments(tool,arguments)
    action=arguments["action"]
    fields=action=="replace" ? ["action","title","steps","expected_revision"] :
        action=="progress" ? ["action","id","status","note","citations","expected_revision"] :
        action=="history" ? (haskey(arguments,"limit") ? ["action","limit"] : ["action"]) : ["action"]
    agent_control_fields(arguments,fields,"plan action")
    session=bound_agent_plan_session(tool.manager,ctx)
    action=="get" && return read_agent_plan(session,ctx)
    action=="history" && return agent_plan_history(session,ctx;limit=get(arguments,"limit",8))
    authorize!(ctx,:read,"agent.plan","session:"*ctx.session_id;reason="Validate current reported plan and owning message citations")
    agent_plan_checkpoint(ctx)
    value=action=="replace" ? build_agent_plan(session,arguments["title"],arguments["steps"];expected_revision=arguments["expected_revision"]) :
        update_agent_plan_step(session,arguments["id"],arguments["status"],arguments["note"],arguments["citations"];expected_revision=arguments["expected_revision"])
    commit_agent_plan!(session,ctx,value;expected_revision=arguments["expected_revision"])
end

function extra_context(tool::PlanTool,session::Session,ctx::RuntimeContext)
    bind_agent_plan_session!(tool.manager,session,ctx)
    haskey(session.metadata,"work_plan") || return ""
    request=PermissionRequest("plan-context",:read,"agent.plan","session:"*ctx.session_id,"Read saved plan context")
    permission_decision(ctx.permissions,request)==Deny && return ""
    value=read_agent_plan(session,ctx);plan=value["plan"]
    plan===nothing && return ""
    summary=Dict("revision"=>plan["revision"],"sha256"=>plan["sha256"],"title"=>plan["title"],"summary"=>value["summary"],
        "steps"=>[Dict("id"=>step["id"],"text"=>cliptext(step["text"],128),"status"=>step["status"]) for step in plan["steps"][1:min(16,end)]],
        "steps_omitted"=>length(plan["steps"])>16)
    "Conversation plan (reported progress; use plan/get for full details and message citation hashes):\n"*bounded_canonical_json(summary;maximum=8*1024)
end
