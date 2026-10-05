struct PlanImpostorTool <: AbstractTool end
ShenScope.tool_name(::PlanImpostorTool)="pretend_read"
ShenScope.tool_schema(::PlanImpostorTool)=ShenScope.object_schema(Dict())
ShenScope.execution_mode(::PlanImpostorTool)=:parallel

@testset "Plan mode scope, inherited tasks and unchanged permission gates" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root)
        @test current_agent_mode()==AgentAct
        @test ShenScope.parse_agent_mode(SubString("plan",1,4))==AgentPlan
        @test_throws ShenScopeError ShenScope.parse_agent_mode(true)
        @test_throws ShenScopeError ShenScope.parse_agent_mode("bypass")
        with_agent_execution_mode(AgentPlan) do
            @test current_agent_mode()==AgentPlan
            @test fetch(@async current_agent_mode())==AgentPlan
            @test fetch(Threads.@spawn current_agent_mode())==AgentPlan
            @test with_agent_execution_mode(current_agent_mode,AgentAct)==AgentPlan
            for category in (:edit,:process,:dynamic,:mcp)
                push!(ctx.permissions.grants,(category,ctx.root))
                @test_throws ShenScopeError authorize!(ctx,category,"fixture",ctx.root)
            end
            @test authorize!(ctx,:read,"read",ctx.root)===nothing
            @test authorize!(ctx,:network,"model",ctx.root)===nothing
            @test authorize!(ctx,:persistence,"agent.plan","session:"*session.id)===nothing
            @test_throws ShenScopeError authorize!(ctx,:persistence,"memory.put",ctx.root)
            fresh=RuntimeContext(root;permissions=ctx.permissions)
            @test_throws ShenScopeError authorize!(fresh,:edit,"write",ctx.root)
            ctx.permissions.rules[:read]=Deny
            @test_throws ShenScopeError authorize!(ctx,:read,"read",ctx.root)
            ctx.permissions.rules[:network]=Deny
            @test_throws ShenScopeError authorize!(ctx,:network,"model",ctx.root)
        end
        @test current_agent_mode()==AgentAct
    end
end

@testset "Reviewed Core tool schemas narrow without trusting plugin hints" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root);tools=core_tools()
        originals=Dict(tool_name(tool)=>canonical(tool_schema(tool)) for tool in tools)
        with_agent_execution_mode("plan") do
            available=ShenScope.active_tools(vcat(tools,AbstractTool[PlanImpostorTool()]),ctx)
            names=Set(tool_name.(available))
            @test all(name->name in names,["read","search","plan","memory","context","models","project","tasks","diagnostics","testing"])
            @test all(name->!(name in names),["write","edit","patch","process","terminal","mcp","extensions","skills","hooks","pretend_read"])
            narrowed=Dict(tool_name(tool)=>tool_schema(tool) for tool in available)
            for (name,forbidden) in (("memory","put"),("context","compact"),("models","refresh"),("project","build"),("tasks","run"),("diagnostics","sample"),("testing","run_set"))
                @test !(forbidden in narrowed[name]["properties"]["action"]["enum"])
                raw=only(tool for tool in tools if tool_name(tool)==name)
                @test_throws ShenScopeError ShenScope.guard_agent_tool(raw,Dict("action"=>forbidden))
            end
            @test all(action->action in narrowed["testing"]["properties"]["action"]["enum"],["editor_catalog","editor_result"])
            @test !execute_call(WriteTool(),ToolCall("write",Dict("path"=>"blocked.py","content"=>"x=1")),ctx).ok
            @test !isfile(joinpath(root,"blocked.py"))
            @test !execute_call(PlanImpostorTool(),ToolCall("pretend_read",Dict()),ctx).ok
        end
        @test all(tool->canonical(tool_schema(tool))==originals[tool_name(tool)],tools)
        @test Set(tool_name.(ShenScope.active_tools(tools,ctx)))==Set(keys(originals))
    end
end

@testset "Persisted mode CAS, ancestry, scope and interrupted notification" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root)
        @test agent_mode_view(session)["mode"]=="act"
        @test agent_mode_view(session)["revision"]==0
        setting=set_agent_mode!(session,ctx,"plan";expected_revision=0)
        @test setting["mode"]=="plan" && setting["committed"] && !setting["notification_disrupted"]
        @test !setting["mode_relaxes_permissions"]
        @test agent_mode_view(load_session(ctx.state_dir,session.id))["sha256"]==setting["sha256"]
        @test_throws ShenScopeError set_agent_mode!(session,ctx,"act";expected_revision=0)
        @test_throws ShenScopeError set_agent_mode!(session,ctx,"act";expected_revision=true)
        foreign=RuntimeContext(root;state_dir=ctx.state_dir)
        @test_throws ShenScopeError set_agent_mode!(session,foreign,"act";expected_revision=1)
        child=branch_session(session,foreign)
        @test agent_mode_view(child)["mode"]=="plan"
        @test agent_mode_view(child)["parent_setting_sha256"]==setting["sha256"]
        @test_throws ShenScopeError branch_session(session,RuntimeContext(root;state_dir=ctx.state_dir);through=true)
        damaged=deepcopy(session.metadata["agent_mode"]);session.metadata["agent_mode"]["mode"]="act"
        @test_throws ShenScopeError agent_mode_view(session)
        session.metadata["agent_mode"]=damaged
        ctx.sink=event->event.kind==:agent_mode_changed ? error("fixture sink failure") : nothing
        outcome=set_agent_mode!(session,ctx,"act";expected_revision=1)
        @test outcome["committed"] && outcome["notification_disrupted"]
        @test agent_mode_view(load_session(ctx.state_dir,session.id))["mode"]=="act"
    end
end
