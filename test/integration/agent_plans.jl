@testset "Real agent loop keeps plans separate from edits across project languages" begin
    for (path,source) in (("calc.py","def add(a,b): return a+b\n"),("calc.js","export const add = (a,b) => a+b;\n"),("calc.rs","pub fn add(a:i32,b:i32)->i32 { a+b }\n"))
        mktempdir() do root
            ctx,session=agent_plan_fixture(root);write(joinpath(root,path),source)
            set_agent_mode!(session,ctx,"plan";expected_revision=0)
            read_request=function(request)
                names=Set(item["name"] for item in request.tools)
                @test "read" in names && "plan" in names && !("write" in names) && !("process" in names)
                @test occursin("user selected plan mode",lowercase(request.messages[1].text))
                response(;calls=[ToolCall("read",Dict("path"=>path))])
            end
            provider=MockProvider(Any[read_request,
                response(;calls=[ToolCall("write",Dict("path"=>"forbidden.txt","content"=>"should not appear")),
                    ToolCall("plan",Dict("action"=>"replace","title"=>"Review the project","expected_revision"=>0,
                        "steps"=>[agent_plan_row("inspect";status="in_progress"),agent_plan_row("verify";dependencies=["inspect"])]))]),
                response("Project inspected; plan saved for review.")])
            @test run_agent!(provider,"Read this project and prepare a plan",ctx;session)=="Project inspected; plan saved for review."
            @test !isfile(joinpath(root,"forbidden.txt")) && read(joinpath(root,path),String)==source
            @test read_agent_plan(session,ctx)["summary"]["statuses"]["in_progress"]==1
            tool_messages=[ShenScope.plain(ShenScope.JSON3.read(message.text)) for message in session.messages if message.role==:tool]
            @test any(message->get(message,"ok",true)==false && occursin("Unknown tool",get(message,"error","")),tool_messages)
            @test agent_mode_view(load_session(ctx.state_dir,session.id))["mode"]=="plan"
            set_agent_mode!(session,ctx,"act";expected_revision=1)
            writer=MockProvider(Any[response(;calls=[ToolCall("write",Dict("path"=>"review.txt","content"=>"Reviewed "*path))]),response("Recorded review")])
            @test run_agent!(writer,"Record the review",ctx;session)=="Recorded review"
            @test read(joinpath(root,"review.txt"),String)=="Reviewed "*path
            @test agent_mode_view(session)["mode"]=="act" && read_agent_plan(session,ctx)["revision"]==1
            @test occursin("Conversation plan",writer.requests[1].messages[1].text)
            ctx.permissions.rules[:edit]=Deny
            denied=MockProvider(Any[response(;calls=[ToolCall("write",Dict("path"=>"denied.txt","content"=>"x"))]),response("Permission refused")])
            run_agent!(denied,"Try a denied edit",ctx;session)
            @test !isfile(joinpath(root,"denied.txt"))
        end
    end
end

@testset "Fresh owning plan context, terminal controls and CLI persistence" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root);save_plan_fixture(session,ctx)
        state=ShenScope.TerminalState()
        ShenScope.terminal_control_command!(state,"/mode plan",session,ctx)
        @test agent_mode_view(session)["mode"]=="plan"
        ShenScope.terminal_control_command!(state,"/plan",session,ctx)
        @test any(line->occursin("reported progress",line),state.lines)
        state.active=true
        @test_throws ShenScopeError ShenScope.terminal_control_command!(state,"/mode act",session,ctx)
        state.active=false
        @test_throws ShenScopeError ShenScope.terminal_control_command!(state,"/mode bypass",session,ctx)
        plan_input=joinpath(root,"plan.json")
        write(plan_input,canonical(Dict("title"=>"Shared workflow","steps"=>[agent_plan_row("review") ])))
        command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(dirname(@__DIR__))) -e 'using ShenScope; exit(ShenScope.main(ARGS))'`
        common=["--root",root,"--state-dir",ctx.state_dir,"--config",joinpath(root,"config.toml"),"--session",session.id]
        result=ShenScope.plain(ShenScope.JSON3.read(read(`$command plan get $common`,String)))
        @test result["revision"]==1 && result["agent_mode"]["mode"]=="plan"
        written=ShenScope.plain(ShenScope.JSON3.read(read(`$command plan replace $plan_input $common --expected-revision 1 --allow-persistence`,String)))
        @test written["committed"] && written["plan"]["revision"]==2
        current=load_session(ctx.state_dir,session.id)
        @test read_agent_plan(current,ctx)["plan"]["title"]=="Shared workflow"
        modes=read(`$command sessions mode $(session.id) --root $root --state-dir $(ctx.state_dir)`,String)
        @test ShenScope.plain(ShenScope.JSON3.read(modes))["mode"]=="plan"
        @test_throws ShenScopeError ShenScope.with_session_run_fence(session,ctx) do
            nothing
        end
        @test !isfile(joinpath(root,"review.txt"))
    end
end
