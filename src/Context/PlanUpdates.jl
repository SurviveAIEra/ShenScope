function build_agent_plan(session::Session,title,rows;expected_revision)
    expected=agent_control_integer(expected_revision,"expected plan revision",0,999_999)
    lock(session.mutex) do
        previous=saved_agent_plan(session)
        (previous===nothing ? 0 : previous.revision)==expected || throw(ShenScopeError(:conflict,"Conversation plan revision changed"))
        label=agent_control_text(title,"plan title",512);steps=agent_plan_steps(rows,session)
        now=utcstamp();created=previous===nothing ? now : previous.created_at
        parent=previous===nothing ? nothing : previous.parent_plan_sha256
        draft=AgentPlanDocument(expected+1,label,steps,created,now,session.id,digest(session.root),parent,"")
        view=agent_plan_body(draft);bounded_canonical_json(view;maximum=AGENT_PLAN_MAX_BYTES)
        AgentPlanDocument(draft.revision,label,steps,created,now,session.id,draft.root_sha256,parent,digest(canonical(view)))
    end
end

function update_agent_plan_step(session::Session,id,status,note,citations;expected_revision)
    agent_control_text(id,"plan step id",64)
    lock(session.mutex) do
        previous=saved_agent_plan(session);previous===nothing && throw(ShenScopeError(:agent_plan,"Create a conversation plan first"))
        rows=agent_plan_step_view.(previous.steps)
        index=findfirst(row->row["id"]==id,rows);index===nothing && throw(ShenScopeError(:agent_plan,"Plan step is absent"))
        rows[index]["status"]=status;rows[index]["note"]=note;rows[index]["citations"]=citations
        build_agent_plan(session,previous.title,rows;expected_revision)
    end
end

function branch_agent_plan!(parent::Session,child::Session,through::Int)
    plan=saved_agent_plan(parent);plan===nothing && return
    rows=agent_plan_step_view.(plan.steps)
    # Partial branches keep intent but reset progress; parent evidence after
    # the branch point cannot become child completion evidence.
    if through<length(parent.messages)
        for row in rows
            row["status"]="pending";row["note"]="Inherited intent from a partial branch; reported progress reset."
            row["citations"]=[item for item in row["citations"] if item["message"]<=through]
        end
    end
    now=utcstamp();draft=AgentPlanDocument(1,plan.title,agent_plan_steps(rows,child),now,now,child.id,digest(child.root),plan.sha256,"")
    body=agent_plan_body(draft);body["sha256"]=digest(canonical(body))
    agent_plan_from_view(body,child)
    session_record!(child,"metadata",Dict("work_plan"=>body))
    nothing
end
