function bind_agent_plan_session!(manager::AgentPlanManager,session::Session,ctx::RuntimeContext)
    session_control_scope(session,ctx)
    lock(manager.mutex) do
        for key in collect(keys(manager.sessions));manager.sessions[key].value===nothing && delete!(manager.sessions,key);end
        key=(ctx.root,ctx.session_id)
        length(manager.sessions)<64 || haskey(manager.sessions,key) || throw(ShenScopeError(:capacity,"Plan session capacity reached"))
        manager.sessions[key]=WeakRef(session)
    end
    session
end

function bound_agent_plan_session(manager::AgentPlanManager,ctx::RuntimeContext)
    value=lock(manager.mutex) do
        get(manager.sessions,(ctx.root,ctx.session_id),WeakRef(nothing)).value
    end
    value isa Session || throw(ShenScopeError(:agent_plan,"Plan tool requires a bound owning conversation"))
    session_control_scope(value,ctx)
    value
end

function agent_plan_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    permission_decision(ctx.permissions,PermissionRequest("plan-read-current",:read,"agent.plan",
        "session:"*ctx.session_id,"Read owning conversation plan"))==Deny &&
        throw(ShenScopeError(:permission,"Plan reads were revoked"))
end

function saved_agent_plan(session::Session)
    lock(session.mutex) do
        value=get(session.metadata,"work_plan",nothing)
        value===nothing ? nothing : agent_plan_from_view(value,session)
    end
end

function read_agent_plan(session::Session,ctx::RuntimeContext)
    session_control_scope(session,ctx)
    authorize!(ctx,:read,"agent.plan","session:"*ctx.session_id;reason="Read the owning conversation's reported plan and message citations")
    agent_plan_checkpoint(ctx)
    value=saved_agent_plan(session)
    result=Dict("schema"=>AGENT_PLAN_SCHEMA,"plan"=>value===nothing ? nothing : agent_plan_document_view(value),
        "revision"=>value===nothing ? 0 : value.revision,"summary"=>value===nothing ? nothing : agent_plan_summary(value),
        "agent_mode"=>agent_mode_view(session),"message_citations"=>agent_plan_message_citations(session),
        "limitations"=>copy(AGENT_PLAN_LIMITATIONS))
    agent_plan_checkpoint(ctx);result
end

function commit_agent_plan!(session::Session,ctx::RuntimeContext,value::AgentPlanDocument;expected_revision)
    session_control_scope(session,ctx)
    authorize!(ctx,:read,"agent.plan","session:"*ctx.session_id;reason="Validate current reported plan and message citations before publication")
    expected=agent_control_integer(expected_revision,"expected plan revision",0,999_999)
    prepared=agent_plan_from_view(agent_plan_document_view(value),session)
    prepared.revision==expected+1 || throw(ShenScopeError(:agent_plan,"Candidate plan revision is not the next version"))
    authorize!(ctx,:persistence,"agent.plan","session:"*ctx.session_id;reason="Save a reported plan in this conversation; no workspace edits or automatic execution")
    agent_plan_checkpoint(ctx)
    lock(session.mutex) do
        agent_plan_checkpoint(ctx)
        previous=saved_agent_plan(session);observed=previous===nothing ? 0 : previous.revision
        observed==expected || throw(ShenScopeError(:conflict,"Conversation plan revision changed"))
        permission_decision(ctx.permissions,PermissionRequest("plan-persist-current",:persistence,"agent.plan",
            "session:"*ctx.session_id,"Save owning plan"))==Deny && throw(ShenScopeError(:permission,"Plan persistence was revoked"))
        agent_plan_from_view(agent_plan_document_view(prepared),session)
        session_record!(session,"metadata",Dict("work_plan"=>agent_plan_document_view(prepared)))
        result=Dict("plan"=>agent_plan_document_view(prepared),"summary"=>agent_plan_summary(prepared),"committed"=>true,
            "notification_disrupted"=>false,"limitations"=>copy(AGENT_PLAN_LIMITATIONS))
        try
            emit!(ctx,:agent_plan_updated,Dict("plan"=>result["plan"],"summary"=>result["summary"],"committed"=>true))
        catch
            result["notification_disrupted"]=true
        end
        result
    end
end

function agent_plan_message_citations(session::Session;limit=32)
    lock(session.mutex) do
        first=max(1,length(session.messages)-limit+1)
        [Dict("message"=>index,"role"=>String(session.messages[index].role),
            "sha256"=>digest(canonical(message_dict(session.messages[index])))) for index in first:length(session.messages)]
    end
end
