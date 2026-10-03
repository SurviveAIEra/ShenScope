function context_fixture(root; session_id="context-owner", rules=Dict(:read=>Allow, :persistence=>Allow, :network=>Allow), approve=request -> :deny, sink=event -> nothing)
    RuntimeContext(root; session_id, state_dir=joinpath(root, "state"), permissions=PermissionPolicy(; rules), approve, sink)
end

function context_transcript!(session; rounds=18, width=2048)
    add_message!(session, Message(:user, "保留中文目标：只修复当前模块，验证真实结果。"))
    for index in 1:rounds
        call = ToolCall("context-call-" * string(index), "read", Dict{String,Any}("path"=>"src/file.jl"))
        add_message!(session, Message(:assistant, "Read evidence " * string(index); calls=[call],
            native=Dict("reasoning_content"=>repeat("private", 80))))
        add_message!(session, Message(:tool, canonical(Dict("ok"=>index % 3 != 0,
            "value"=>Dict("text"=>repeat("证据🙂", width), "tail"=>"END " * string(index)))); call_id=call.id))
    end
    session
end

@testset "Context settings and exact model envelopes" begin
    @test ShenScope.bounded_json_object("{\"x\":1}")==Dict("x"=>1)
    for raw in ("{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "{\"a\":{\"x\":1,\"x\":2}}", "{} {}", "{\"a\":[[[[[1]]]]]}")
        @test_throws ShenScopeError ShenScope.bounded_json_object(raw;max_depth=4)
    end
    @test_throws ShenScopeError ShenScope.bounded_json_object("{\"a\":[1,2,3,4]}";max_nodes=3)
    @test_throws ShenScopeError ShenScope.bounded_json_object("{\"a\":\"long string\"}";max_string_bytes=4)
    @test context_config(Dict()).auto_compact
    @test ShenScope.estimate_text_tokens(repeat("中文",100)) > cld(ncodeunits(repeat("中文",100)),3)
    @test ShenScope.estimate_text_tokens(repeat("🙂",100)) > cld(ncodeunits(repeat("🙂",100)),3)
    for document in (Dict("recent_messages"=>true), Dict("recovery_attempts"=>5),
        Dict("instruction_names"=>["../AGENTS.md"]), Dict("user_files"=>["relative.md"]),
        Dict("paths"=>["a", "a"]), Dict("auto_compact"=>1), Dict("unknown"=>1))
        @test_throws ShenScopeError context_config(Dict("context"=>document))
    end
    config=deepcopy(ShenScope.DEFAULT_CONFIG)
    config["provider"]["capabilities"]=Dict{String,Any}("context_window"=>8192, "max_output"=>512, "reasoning"=>true)
    @test capabilities(provider_from_config(config)).context_window==8192
    config["provider"]["capabilities"]["tools"]="yes"
    @test_throws ShenScopeError provider_from_config(config)
    for protocol in (:openai_chat, :openai_responses, :anthropic, :gemini, :ollama)
        lookups=Ref(0)
        provider=HTTPProvider(ProviderConfig(; protocol, endpoint="http://127.0.0.1:1234", model="fixture"), key -> begin lookups[]+=1; "secret" end)
        tool=declaration(ReadTool())
        request=ModelRequest([Message(:system, "system"), Message(:user, "中文"), Message(:assistant, "text";
            native=Dict("reasoning_content"=>repeat("reason", 1000)))], [tool], 128, Dict{String,Any}())
        measure=context_measure(provider, request, ContextConfig())
        @test measure.message_bytes > 6000
        @test measure.tools_bytes > 100
        @test measure.wire_bytes > 0
        @test measure.estimated_tokens >= estimate_request_tokens(request)
        @test lookups[]==0
        @test measure_view(measure)["token_source"]=="byte_and_unicode_estimate"
    end
end

@testset "Instruction scope discovery, permissions and source revisions" begin
    mktempdir() do root
        mkpath(joinpath(root, "src", "deep")); mkpath(joinpath(root, "unrelated"))
        write(joinpath(root, "AGENTS.md"), "root instruction")
        write(joinpath(root, "src", "AGENTS.md"), "src instruction")
        write(joinpath(root, "src", "deep", "SHENSCOPE.md"), "deep instruction")
        write(joinpath(root, "unrelated", "AGENTS.md"), "must not load")
        ctx=context_fixture(root)
        message=Message(:assistant, ""; calls=[ToolCall("read", Dict("path"=>"src/deep/file.jl"))])
        sources=load_project_instructions(ctx, [message], ContextConfig())
        @test length(sources)==3
        @test [source.text for source in sources]==["root instruction", "src instruction", "deep instruction"]
        @test all(source -> source.sha256==digest(source.text), sources)
        @test !occursin("must not load", ShenScope.render_instructions(sources, root))
        denied_call=ToolCall("failed-scope", "read", Dict{String,Any}("path"=>".env"))
        denied_messages=[Message(:assistant,"";calls=[denied_call]),Message(:tool,canonical(Dict("ok"=>false,"error"=>"denied"));call_id=denied_call.id)]
        @test length(load_project_instructions(ctx,denied_messages,ContextConfig()))==1
        write(joinpath(root, "src", "AGENTS.md"), "updated instruction")
        @test load_project_instructions(ctx, [message], ContextConfig())[2].sha256 != sources[2].sha256
        denied=context_fixture(root; rules=Dict(:read=>Deny))
        @test_throws ShenScopeError load_project_instructions(denied, [message], ContextConfig())
        ctx.permissions.rules[:read]=Ask
        ctx.approve=request -> begin ctx.permissions.rules[:read]=Deny; :once end
        @test_throws ShenScopeError load_project_instructions(ctx, [message], ContextConfig())
        ctx.permissions.rules[:read]=Allow
        write(joinpath(root, "AGENTS.md"), UInt8[0xff])
        @test_throws ShenScopeError load_project_instructions(ctx, [message], ContextConfig())
        write(joinpath(root, "AGENTS.md"), repeat("x", 300))
        @test_throws ShenScopeError load_project_instructions(ctx, [message], ContextConfig(; source_bytes=256))
    end
    mktempdir() do parent
        root=joinpath(parent, "project"); mkdir(root)
        user=joinpath(parent, "user.md"); write(user, "explicit user instruction")
        ctx=context_fixture(root)
        sources=load_project_instructions(ctx, Message[], ContextConfig(; user_files=[user]))
        @test only(sources).scope==:user
        symlink(user, joinpath(root, "AGENTS.md"))
        @test_throws ShenScopeError load_project_instructions(ctx, Message[], ContextConfig())
        rm(joinpath(root, "AGENTS.md")); symlink(parent, joinpath(root, "escape"))
        @test_throws ShenScopeError load_project_instructions(ctx, Message[], ContextConfig(; paths=["escape/file"]))
    end
end

@testset "Balanced tool groups, no reasoning split and Unicode excerpts" begin
    calls=[ToolCall("a", "read", Dict{String,Any}()), ToolCall("b", "read", Dict{String,Any}())]
    messages=[Message(:user, "goal"), Message(:assistant, ""; calls), Message(:tool, "{}"; call_id="b"),
        Message(:user, "steering"), Message(:tool, "{}"; call_id="a"), Message(:assistant, "done")]
    groups=context_groups(messages)
    @test [(group.first, group.last, group.complete) for group in groups]==[(1,1,true), (2,5,true), (6,6,true)]
    @test ShenScope.context_recent_boundary(messages, groups, 3)==2
    @test !last(context_groups(messages[1:4])).complete
    @test_throws ShenScopeError context_groups([Message(:tool, "{}"; call_id="missing")])
    @test_throws ShenScopeError context_groups(vcat(messages, [Message(:tool, "{}"; call_id="a")]))
    @test_throws ShenScopeError context_groups([Message(:assistant, ""; calls=[calls[1], calls[1]])])
    for capacity in (64, 65, 128, 255, 256, 1024)
        excerpt=ShenScope.context_excerpt(repeat("中文🙂é", 1000), capacity)
        @test isvalid(excerpt)
        @test ncodeunits(excerpt)<=capacity
        @test occursin("omitted", excerpt)
    end
end

@testset "Durable context projections preserve transcripts and provenance" begin
    mktempdir() do root
        ctx=context_fixture(root); session=new_session(ctx)
        context_transcript!(session; rounds=20, width=200)
        add_message!(session, Message(:user, "最新指令必须完整保留"))
        original=canonical(ShenScope.message_dict.(session.messages))
        manager=ContextManager(Dict("context"=>Dict("max_request_bytes"=>16000, "recent_messages"=>4,
            "checkpoint_bytes"=>4096, "tool_preview_bytes"=>512)))
        request, projection=prepare_context!(MockProvider(Any[]), session, ctx; manager, max_output=128)
        @test projection.checkpoint !== nothing
        @test projection.measure.wire_bytes<=16000
        @test length(request.messages)<length(session.messages)
        @test last(request.messages).text=="最新指令必须完整保留"
        @test canonical(ShenScope.message_dict.(session.messages))==original
        replay=load_session(ctx.state_dir, ctx.session_id)
        @test replay.metadata["context_checkpoint"]["id"]==projection.checkpoint.id
        @test canonical(ShenScope.message_dict.(replay.messages))==original
        replay_manager=ContextManager(Dict("context"=>Dict("max_request_bytes"=>16000,"recent_messages"=>4,"checkpoint_bytes"=>4096,"tool_preview_bytes"=>512)))
        _, restored=prepare_context!(MockProvider(Any[]), replay, ctx; manager=replay_manager, max_output=128)
        @test restored.checkpoint.id==projection.checkpoint.id
        index=first(projection.checkpoint.sources)["message"]
        reference=first(projection.checkpoint.sources)
        page=context_source(replay_manager, ctx, index; expected_sha256=reference["sha256"], max_bytes=64)
        @test page["source"]["sha256"]==reference["sha256"]
        @test page["next_byte"]>page["start_byte"]
        @test_throws ShenScopeError context_source(replay_manager, ctx, index; expected_sha256=repeat("0",64))
        @test_throws ShenScopeError context_source(replay_manager, ctx, 9999)
        child=branch_session(replay, context_fixture(root; session_id="context-branch"))
        @test child.metadata["context_checkpoint"]["session_id"]==child.id
        @test child.metadata["context_checkpoint"]["prefix_sha256"]==projection.checkpoint.prefix_sha256
        short=branch_session(replay, context_fixture(root; session_id="context-short"); through=1)
        @test !haskey(short.metadata,"context_checkpoint")
        bad=deepcopy(replay.metadata["context_checkpoint"]); bad["text"] *= " tampered"
        replay.metadata["context_checkpoint"]=bad
        @test_throws ShenScopeError prepare_context!(MockProvider(Any[]), replay, ctx; manager=replay_manager, max_output=128)
        @test_throws ShenScopeError context_status(replay_manager, context_fixture(root;session_id="foreign"))
    end
end

@testset "Compaction failure is atomic and fixed context is retained" begin
    mktempdir() do root
        ctx=context_fixture(root); session=new_session(ctx); context_transcript!(session; rounds=6, width=180)
        manager=ContextManager(Dict("context"=>Dict("max_request_bytes"=>5000, "recent_messages"=>2,"checkpoint_bytes"=>1024,"tool_preview_bytes"=>256)))
        ctx.permissions.rules[:persistence]=Ask
        ctx.approve=request -> begin
            session.messages[1]=Message(:user,"Changed objective after approval")
            :once
        end
        @test_throws ShenScopeError prepare_context!(MockProvider(Any[]),session,ctx;manager,max_output=128,force=true)
        @test !haskey(session.metadata,"context_checkpoint")
        ctx.permissions.rules[:persistence]=Deny
        @test_throws ShenScopeError prepare_context!(MockProvider(Any[]),session,ctx;manager,max_output=128,force=true)
        @test !haskey(session.metadata,"context_checkpoint")
        ctx.permissions.rules[:persistence]=Allow
        add_message!(session,Message(:user,repeat("large directive",2000)))
        @test_throws ShenScopeError prepare_context!(MockProvider(Any[]),session,ctx;manager,max_output=128)
        @test !haskey(session.metadata,"context_checkpoint")
        @test_throws ShenScopeError execute(ContextTool(manager), Dict("action"=>"compact"),ctx)
    end
end

@testset "Original tool artifacts are scoped, permissioned and digest checked" begin
    mktempdir() do root
        ctx=context_fixture(root); session=new_session(ctx); manager=ContextManager()
        ShenScope.bind_context_session!(manager, session, ctx)
        result=ToolResult("artifact-call",true,Dict("output"=>repeat("中文🙂", 20000)),nothing)
        artifact=ShenScope.archive_output!(ctx,result)
        @test occursin(r"^[0-9a-f]{64}$",artifact)
        add_message!(session,Message(:assistant,"";calls=[ToolCall("artifact-call","process",Dict{String,Any}())]))
        text=ShenScope.trim_tool_result(result;artifact_sha256=artifact)
        @test ncodeunits(text)<=32*1024
        @test parsejson(text)["artifact_sha256"]==artifact
        add_message!(session,Message(:tool,text;call_id="artifact-call"))
        recovered=context_artifact(manager,ctx,artifact;max_bytes=1024)
        @test recovered["truncated"]
        @test occursin("中文",recovered["text"])
        @test_throws ShenScopeError context_artifact(manager,ctx,repeat("0",64))
        path=joinpath(ctx.state_dir,"outputs",ctx.session_id,artifact*".json")
        write(path,"tampered")
        @test_throws ShenScopeError context_artifact(manager,ctx,artifact)
        ctx.permissions.rules[:persistence]=Deny
        @test ShenScope.archive_output!(ctx,ToolResult("denied",true,Dict("x"=>1),nothing))===nothing
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError context_source(manager,ctx,1)
    end
end

@testset "Optional model summaries bind citations and shared budget" begin
    mktempdir() do root
        ctx=context_fixture(root); session=new_session(ctx); context_transcript!(session;rounds=4,width=20)
        config=ContextConfig(;checkpoint_bytes=4096,recent_messages=2)
        checkpoint=ShenScope.build_context_checkpoint(session,session.messages,5,config)
        reference=first(checkpoint.sources)
        data=Dict("version"=>1,"objective"=>"保留中文目标","constraints"=>"only current module", "work"=>"observed evidence",
            "next"=>"verify", "citations"=>[Dict("message"=>reference["message"],"sha256"=>reference["sha256"])])
        provider=MockProvider(Any[response(canonical(data);usage=Usage(;input_tokens=23,output_tokens=17))])
        summary=ShenScope.summarize_context_checkpoint!(provider,session,ctx,checkpoint,config)
        @test summary.method==:model
        @test isempty(only(provider.requests).tools)
        @test budget_status(ctx.budget)["tokens"]==40
        @test session.usage[1].input_tokens==23
        @test summary.model["provider"]=="mock"
        @test occursin("not independently verified",summary.text)
        invalid=deepcopy(data);invalid["citations"][1]["sha256"]=repeat("0",64)
        previous=session.metadata["context_checkpoint"]["id"]
        bad=MockProvider(Any[response(canonical(invalid);usage=Usage(;input_tokens=3,output_tokens=2))])
        @test_throws ShenScopeError ShenScope.summarize_context_checkpoint!(bad,session,ctx,checkpoint,config)
        @test session.metadata["context_checkpoint"]["id"]==previous
        @test budget_status(ctx.budget)["tokens"]==45
        @test isempty(ctx.budget.reservations)
    end
end
