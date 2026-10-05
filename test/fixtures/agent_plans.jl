function agent_plan_fixture(root;permissions=PermissionPolicy(;rules=Dict(category=>Allow for category in
        (:read,:edit,:process,:network,:dynamic,:persistence,:mcp))),kwargs...)
    ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions,kwargs...)
    session=new_session(ctx;title="General project plan")
    ShenScope.add_message!(session,Message(:user,"Inspect and improve this project"))
    ctx,session
end
function agent_plan_row(id,text=id;status="pending",dependencies=String[],note="",citations=Any[])
    Dict{String,Any}("id"=>id,"text"=>text,"status"=>status,"dependencies"=>dependencies,"note"=>note,"citations"=>citations)
end
agent_plan_citation(session,index=1)=Dict("message"=>index,"sha256"=>digest(canonical(ShenScope.message_dict(session.messages[index]))))
function save_plan_fixture(session,ctx;title="Inspect, change and verify",steps=[agent_plan_row("read"),agent_plan_row("change";dependencies=["read"])],revision=0)
    plan=build_agent_plan(session,title,steps;expected_revision=revision)
    commit_agent_plan!(session,ctx,plan;expected_revision=revision)
end
