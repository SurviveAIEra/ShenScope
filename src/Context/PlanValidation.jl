function agent_plan_citations(value,session::Session)
    value isa AbstractVector && length(value)<=8 || throw(ShenScopeError(:agent_plan,"Plan citation count exceeds bounds"))
    result=AgentPlanCitation[];seen=Set{Int}()
    for citation in value
        agent_control_fields(citation,["message","sha256"],"plan citation")
        index=agent_control_integer(citation["message"],"plan citation message",1,length(session.messages))
        hash=agent_control_hash(citation["sha256"],"plan citation hash")
        index in seen && throw(ShenScopeError(:agent_plan,"Duplicate plan citation"));push!(seen,index)
        digest(canonical(message_dict(session.messages[index])))==hash ||
            throw(ShenScopeError(:conflict,"Plan citation no longer matches the owning conversation"))
        push!(result,AgentPlanCitation(index,hash))
    end
    result
end

function agent_plan_steps(value,session::Session)
    value isa AbstractVector && 1<=length(value)<=AGENT_PLAN_MAX_STEPS || throw(ShenScopeError(:agent_plan,"Plan step count exceeds bounds"))
    result=AgentPlanStep[];seen=Set{String}();active=0
    for row in value
        agent_control_fields(row,["id","text","status","dependencies","note","citations"],"plan step")
        id=agent_control_text(row["id"],"plan step id",64)
        occursin(r"^[A-Za-z0-9_-]+$",id) && !(id in seen) || throw(ShenScopeError(:agent_plan,"Invalid or duplicate plan step id"))
        push!(seen,id);text=agent_control_text(row["text"],"plan step text",1024)
        status=row["status"];status in AGENT_PLAN_STATUSES || throw(ShenScopeError(:agent_plan,"Unknown plan step status"))
        active+=status=="in_progress"
        dependencies=row["dependencies"]
        dependencies isa AbstractVector && length(dependencies)<=16 || throw(ShenScopeError(:agent_plan,"Plan dependency count exceeds bounds"))
        deps=String[agent_control_text(item,"plan dependency id",64) for item in dependencies]
        length(unique(deps))==length(deps) && !(id in deps) || throw(ShenScopeError(:agent_plan,"Duplicate or self plan dependency"))
        note=agent_control_text(row["note"],"plan progress note",2048;empty=true)
        citations=agent_plan_citations(row["citations"],session)
        status=="completed" && isempty(citations) && throw(ShenScopeError(:agent_plan,"Reported completed steps require an owned message citation"))
        push!(result,AgentPlanStep(id,text,status,deps,note,citations))
    end
    active<=1 || throw(ShenScopeError(:agent_plan,"At most one plan step may be in progress"))
    agent_plan_validate_dependencies(result)
    result
end

function agent_plan_validate_dependencies(steps::Vector{AgentPlanStep})
    lookup=Dict(step.id=>step for step in steps);pending=Dict(step.id=>length(step.dependencies) for step in steps)
    reverse=Dict(step.id=>String[] for step in steps)
    for step in steps,dependency in step.dependencies
        haskey(lookup,dependency) || throw(ShenScopeError(:agent_plan,"Plan references an unknown dependency"))
        push!(reverse[dependency],step.id)
        step.status in ("in_progress","completed") && lookup[dependency].status!="completed" &&
            throw(ShenScopeError(:agent_plan,"An active or completed step requires reported-completed dependencies"))
    end
    ready=sort!([id for (id,count) in pending if count==0]);visited=0
    while !isempty(ready)
        id=popfirst!(ready);visited+=1
        for dependent in reverse[id]
            pending[dependent]-=1
            pending[dependent]==0 && push!(ready,dependent)
        end
    end
    visited==length(steps) || throw(ShenScopeError(:agent_plan,"Plan dependencies contain a cycle"))
    nothing
end

function agent_plan_from_view(value,session::Session)
    bounded_canonical_json(value;maximum=AGENT_PLAN_MAX_BYTES)
    agent_control_fields(value,["schema","revision","title","steps","created_at","updated_at","session_id",
        "root_sha256","parent_plan_sha256","sha256"],"conversation plan")
    value["schema"]==AGENT_PLAN_SCHEMA && value["session_id"]==session.id && value["root_sha256"]==digest(session.root) ||
        throw(ShenScopeError(:permission,"Plan belongs to another conversation or schema"))
    revision=agent_control_integer(value["revision"],"plan revision",1,1_000_000)
    title=agent_control_text(value["title"],"plan title",512)
    created=agent_control_text(value["created_at"],"plan creation timestamp",64)
    updated=agent_control_text(value["updated_at"],"plan update timestamp",64)
    parent=value["parent_plan_sha256"];parent===nothing || agent_control_hash(parent,"parent plan hash")
    hash=agent_control_hash(value["sha256"],"plan hash")
    digest(canonical(Dict(key=>item for (key,item) in value if key!="sha256")))==hash || throw(ShenScopeError(:conflict,"Plan digest changed"))
    AgentPlanDocument(revision,title,agent_plan_steps(value["steps"],session),created,updated,session.id,digest(session.root),parent,hash)
end
