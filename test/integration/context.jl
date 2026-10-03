@testset "HTTP context overflow recovers before delivery without replay" begin
    mktempdir() do root
        ctx=context_fixture(root); session=new_session(ctx); context_transcript!(session;rounds=30,width=80)
        original_count=length(session.messages)
        requests=Dict{String,Any}[]; events=AgentEvent[];ctx.sink=event->push!(events,event)
        handler=request -> begin
            push!(requests,parsejson(String(request.body)))
            length(requests)==1 && return HTTP.Response(400,canonical(Dict("error"=>Dict("code"=>"context_length_exceeded",
                "message"=>"foreign secret details must never leave the error envelope"))))
            HTTP.Response(200,sse(Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("content"=>"Resumed with original evidence"),"finish_reason"=>"stop")]))*
                sse(Dict("choices"=>[],"usage"=>Dict("prompt_tokens"=>44,"completion_tokens"=>7)))*"data: [DONE]\n\n")
        end
        mock_http(handler) do endpoint
            provider=HTTPProvider(ProviderConfig(;endpoint,retries=0))
            tools=core_tools(;tasks=false,mcp=false,skills=false,hooks=false)
            @test run_agent!(provider,"Continue without repeating previous tools",ctx;session,tools)=="Resumed with original evidence"
            @test length(requests)==2
            @test ncodeunits(canonical(requests[2]))<ncodeunits(canonical(requests[1]))
            @test session.status==:complete
            @test length(session.messages)==original_count+2
            @test count(message->message.text=="Continue without repeating previous tools",session.messages)==1
            @test count(event->event.kind==:context_recovery,events)==1
            @test !any(event->event.kind==:tool_started,events)
            @test !occursin("foreign secret details",canonical([event.payload for event in events]))
            @test budget_status(ctx.budget)["steps"]==2
            @test budget_status(ctx.budget)["tokens"]==51
            @test isempty(ctx.budget.reservations)
            @test load_session(ctx.state_dir,session.id).metadata["context_checkpoint"]["covered"]>0
        end
    end
end

@testset "Model network approval respects the remaining shared wall-clock budget" begin
    mktempdir() do root
        requests=Ref(0)
        mock_http(request->begin requests[]+=1;HTTP.Response(200,"data: [DONE]\n\n") end) do endpoint
            ctx=context_fixture(root;rules=Dict(:network=>Ask))
            ctx.approve=request->begin
                ctx.budget.started_ns=time_ns()-UInt64((ctx.budget.limits.max_seconds+1)*1e9)
                :once
            end
            request=ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}())
            cause=try stream_chat(HTTPProvider(ProviderConfig(;endpoint,retries=0)),request,(kind,payload)->nothing,ctx);nothing catch error;error end
            @test cause isa ShenScopeError
            @test cause.code==:budget
            @test requests[]==0
        end
        attempts=Ref(0)
        wire=sse(Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("content"=>"warm"),"finish_reason"=>"stop")]))*"data: [DONE]\n\n"
        mock_http(request->begin attempts[]+=1;attempts[]>1 && sleep(.3);HTTP.Response(200,wire) end) do endpoint
            ctx=context_fixture(root)
            request=ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}())
            provider=HTTPProvider(ProviderConfig(;endpoint,retries=0,timeout=5.0))
            sink=(kind,payload)->nothing
            stream_chat(provider,request,sink,ctx)
            ctx.budget=BudgetLedger(BudgetLimits(;max_seconds=.15))
            started=time()
            cause=try stream_chat(provider,request,sink,ctx);nothing catch error;error end
            @test cause isa ShenScopeError
            @test cause.code==:budget
            @test time()-started<1.0
            @test attempts[]==2
        end
    end
end

@testset "Reasoning and partial tool arguments fence model retry and recovery" begin
    mktempdir() do root
        for (name, frame, terminal) in [
            ("reasoning-eof", Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("reasoning_content"=>"PRIVATE REASONING"))]), ""),
            ("reasoning-overflow",Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("reasoning_content"=>"PRIVATE REASONING"))]),sse(Dict("error"=>Dict("code"=>"context_length_exceeded")))),
            ("tool-overflow",Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("tool_calls"=>[Dict("index"=>0,"id"=>"partial-call","function"=>Dict("name"=>"write","arguments"=>"{\"path\":"))]))]),sse(Dict("error"=>Dict("code"=>"context_length_exceeded"))))]
            requests=Ref(0);events=AgentEvent[]
            ctx=context_fixture(root;session_id=name,sink=event->push!(events,event));session=new_session(ctx)
            mock_http(request->begin requests[]+=1;HTTP.Response(200,sse(frame)*terminal) end) do endpoint
                provider=HTTPProvider(ProviderConfig(;endpoint,retries=3))
                @test_throws ShenScopeError run_agent!(provider,"Inspect",ctx;session,tools=AbstractTool[WriteTool(),ContextTool()])
                @test requests[]==1
                @test session.status==:interrupted
                @test !any(event->event.kind in (:model_retry,:context_recovery,:tool_started),events)
                @test any(message->get(message.native,"interrupted",false),session.messages)
                @test !occursin("PRIVATE REASONING",canonical([event.payload for event in events]))
                @test isempty(ctx.budget.reservations)
            end
        end
    end
end

@testset "Completed stream calls remain undispatched when a later call is malformed" begin
    mktempdir() do root
        ctx=context_fixture(root);session=new_session(ctx)
        calls=[Dict("index"=>0,"id"=>"first-valid","function"=>Dict("name"=>"write","arguments"=>canonical(Dict("path"=>"must-not-exist","content"=>"not executed")))),
            Dict("index"=>1,"id"=>"second-invalid","function"=>Dict("name"=>"read","arguments"=>"{"))]
        frame=Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("tool_calls"=>calls),"finish_reason"=>"tool_calls")])
        requests=Ref(0)
        mock_http(request->begin requests[]+=1;HTTP.Response(200,sse(frame)) end) do endpoint
            provider=HTTPProvider(ProviderConfig(;endpoint,retries=2))
            @test_throws ShenScopeError run_agent!(provider,"Read before any edit",ctx;session,tools=AbstractTool[ReadTool(),WriteTool(),ContextTool()])
            @test requests[]==1
            @test !isfile(joinpath(root,"must-not-exist"))
            tool=only(message for message in session.messages if message.role==:tool)
            @test tool.call_id=="first-valid"
            @test occursin("not executed",tool.text)
            @test all(group->group.complete,context_groups(session.messages))
            continuation=MockProvider(Any[response("Continue with evidence")])
            @test run_agent!(continuation,"Continue",ctx;session,tools=AbstractTool[ContextTool()])=="Continue with evidence"
            @test !isfile(joinpath(root,"must-not-exist"))
        end
    end
end

@testset "Provider usage survives failed context attempts and disabled recovery" begin
    mktempdir() do root
        usage=sse(Dict("choices"=>[],"usage"=>Dict("prompt_tokens"=>11,"completion_tokens"=>2)))
        failure=sse(Dict("error"=>Dict("code"=>"context_length_exceeded")))
        ctx=context_fixture(root);session=new_session(ctx);count=Ref(0)
        mock_http(request->begin count[]+=1;HTTP.Response(200,usage*failure) end) do endpoint
            @test_throws ShenScopeError run_agent!(HTTPProvider(ProviderConfig(;endpoint,retries=2)),"task",ctx;session,tools=AbstractTool[ContextTool()])
            @test count[]==1
            @test budget_status(ctx.budget)["tokens"]==13
            @test only(session.usage).input_tokens==11
            @test isempty(ctx.budget.reservations)
        end
        ctx=context_fixture(root;session_id="recovery-disabled");session=new_session(ctx);count[]=0
        manager=ContextManager(Dict("context"=>Dict("auto_compact"=>false)))
        mock_http(request->begin count[]+=1;HTTP.Response(400,canonical(Dict("error"=>Dict("code"=>"context_length_exceeded")))) end) do endpoint
            @test_throws ShenScopeError run_agent!(HTTPProvider(ProviderConfig(;endpoint,retries=0)),"task",ctx;session,tools=AbstractTool[ContextTool(manager)])
            @test count[]==1
            @test !haskey(session.metadata,"context_checkpoint")
        end
        for status in (400,413,422)
            @test ShenScope.http_error(status,Dict("error"=>Dict("code"=>"context_length_exceeded"))).code==:context_overflow
        end
        @test ShenScope.http_error(401,Dict("error"=>Dict("code"=>"context_length_exceeded"))).code==:authentication
        @test ShenScope.http_error(400,Dict("message"=>"maximum context length")).code==:request
        @test ShenScope.http_error(400,Dict("error"=>"context_length_exceeded")).code==:request
    end
end
