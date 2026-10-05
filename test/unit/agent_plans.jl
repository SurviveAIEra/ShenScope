@testset "Bounded owning plans, dependency validation and cited progress" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root)
        @test read_agent_plan(session,ctx)["plan"]===nothing
        saved=save_plan_fixture(session,ctx)
        @test saved["committed"] && saved["summary"]["steps"]==2
        @test !saved["summary"]["automatic_execution"] && !saved["summary"]["progress_independently_verified"]
        @test read_agent_plan(session,ctx)["message_citations"][1]==merge(agent_plan_citation(session),Dict("role"=>"user"))
        @test read_agent_plan(load_session(ctx.state_dir,session.id),ctx)["plan"]["sha256"]==saved["plan"]["sha256"]
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row("same"),agent_plan_row("same")];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row("one";dependencies=["absent"])];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row("one";dependencies=["two"]),agent_plan_row("two";dependencies=["one"])];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row("one";status="in_progress"),agent_plan_row("two";status="in_progress")];expected_revision=1)
        @test_throws ShenScopeError update_agent_plan_step(session,"change","in_progress","",Any[];expected_revision=1)
        @test_throws ShenScopeError update_agent_plan_step(session,"read","completed","",Any[];expected_revision=1)
        forged=agent_plan_citation(session);forged["sha256"]=repeat("0",64)
        @test_throws ShenScopeError update_agent_plan_step(session,"read","completed","",[forged];expected_revision=1)
        boolean=agent_plan_citation(session);boolean["message"]=true
        @test_throws ShenScopeError update_agent_plan_step(session,"read","completed","",[boolean];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row("x";note=repeat("z",2049))];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"bad",[agent_plan_row(string(i)) for i in 1:65];expected_revision=1)
        @test_throws ShenScopeError build_agent_plan(session,"oversize",[agent_plan_row(string(i);note=repeat("n",2048)) for i in 1:64];expected_revision=1)
        candidate=update_agent_plan_step(session,"read","completed","Inspected project",[agent_plan_citation(session)];expected_revision=1)
        published=commit_agent_plan!(session,ctx,candidate;expected_revision=1)
        @test published["summary"]["statuses"]["completed"]==1
        @test_throws ShenScopeError commit_agent_plan!(session,ctx,candidate;expected_revision=1)
        next=update_agent_plan_step(session,"change","in_progress","Ready to edit",Any[];expected_revision=2)
        commit_agent_plan!(session,ctx,next;expected_revision=2)
        @test agent_plan_history(session,ctx;limit=2)["older_revisions_omitted"]
        @test [item["revision"] for item in agent_plan_history(session,ctx;limit=2)["items"]]==[3,2]
        @test_throws ShenScopeError agent_plan_history(session,ctx;limit=true)
        @test_throws ShenScopeError agent_plan_history(session,ctx;limit=17)
        @test_throws ShenScopeError read_agent_plan(session,RuntimeContext(root;state_dir=ctx.state_dir))
        damaged=deepcopy(session.metadata["work_plan"]);session.metadata["work_plan"]["session_id"]="foreign"
        @test_throws ShenScopeError read_agent_plan(session,ctx)
        session.metadata["work_plan"]=damaged
        ShenScope.add_message!(session,Message(:assistant,"Observation after the branch point"))
        child=branch_session(session,RuntimeContext(root;state_dir=ctx.state_dir);through=1)
        child_ctx=RuntimeContext(root;session_id=child.id,state_dir=ctx.state_dir,permissions=ctx.permissions)
        inherited=read_agent_plan(child,child_ctx)
        @test inherited["summary"]["statuses"]["pending"]==2
        @test inherited["plan"]["parent_plan_sha256"]==damaged["sha256"]
        @test inherited["plan"]["session_id"]==child.id && inherited["revision"]==1
        full=branch_session(session,RuntimeContext(root;state_dir=ctx.state_dir))
        @test ShenScope.saved_agent_plan(full).steps[1].status=="completed"
        @test length(agent_plan_history(child,child_ctx)["items"])==1
    end
end

@testset "Plan permission revocation, cancellation and durable publication receipt" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root)
        value=build_agent_plan(session,"Review",[agent_plan_row("inspect")];expected_revision=0)
        ctx.permissions.rules[:persistence]=Ask
        ctx.approve=request->begin ctx.permissions.rules[:read]=Deny;:once end
        @test_throws ShenScopeError commit_agent_plan!(session,ctx,value;expected_revision=0)
        @test !haskey(session.metadata,"work_plan")
        ctx.permissions.rules[:read]=Allow
        ctx.approve=request->begin ctx.permissions.rules[:persistence]=Deny;:once end
        @test_throws ShenScopeError commit_agent_plan!(session,ctx,value;expected_revision=0)
        @test !haskey(session.metadata,"work_plan")
        ctx.permissions.rules[:persistence]=Ask
        ctx.approve=request->begin cancel!(ctx.cancellation);:once end
        @test_throws ShenScopeError commit_agent_plan!(session,ctx,value;expected_revision=0)
        @test !haskey(session.metadata,"work_plan")
        ctx.cancellation=CancellationToken();ctx.permissions.rules[:persistence]=Allow
        ctx.sink=event->event.kind==:agent_plan_updated ? error("fixture observer failure") : nothing
        saved=commit_agent_plan!(session,ctx,value;expected_revision=0)
        @test saved["committed"] && saved["notification_disrupted"]
        @test read_agent_plan(load_session(ctx.state_dir,session.id),ctx)["revision"]==1
        tool=PlanTool();bind_agent_plan_session!(tool.manager,session,ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"get","mode"=>"act"),ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"replace","title"=>"missing fields"),ctx)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError read_agent_plan(session,ctx)
        @test_throws ShenScopeError agent_plan_history(session,ctx)
        @test ShenScope.extra_context(tool,session,ctx)==""
    end
end
