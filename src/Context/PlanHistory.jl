function agent_plan_history(session::Session,ctx::RuntimeContext;limit=8)
    limit=agent_control_integer(limit,"plan history limit",1,16)
    session_control_scope(session,ctx)
    authorize!(ctx,:read,"agent.plan","session:"*ctx.session_id;reason="Read a bounded window of recorded conversation plan revisions")
    versions=Dict{String,Any}[];last_revision=0
    walk_journal(session.journal;maximum_bytes=128*1024^2,checkpoint=()->agent_plan_checkpoint(ctx)) do record,sequence,bytes
        get(record,"kind",nothing)=="metadata" || return
        values=get(record,"value",nothing);values isa AbstractDict || throw(ShenScopeError(:storage,"Invalid recorded conversation metadata"))
        value=get(values,"work_plan",nothing);value===nothing && return
        plan=agent_plan_from_view(value,session)
        plan.revision==last_revision+1 || throw(ShenScopeError(:storage,"Recorded plan revisions are not contiguous"))
        last_revision=plan.revision
        push!(versions,agent_plan_document_view(plan));length(versions)>limit && popfirst!(versions)
    end
    agent_plan_checkpoint(ctx)
    result=Dict("items"=>reverse(versions),"latest_revision"=>last_revision,"limit"=>limit,"older_revisions_omitted"=>last_revision>length(versions),
        "limitations"=>copy(AGENT_PLAN_LIMITATIONS))
    bounded_canonical_json(result;maximum=2*1024^2)
    result
end
