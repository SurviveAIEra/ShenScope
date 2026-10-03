using HTTP, Sockets

function mock_http(f::Function,handler::Function)
    listener=listen(ip"127.0.0.1",0)
    port=getsockname(listener)[2]
    server=HTTP.serve!(handler,listener;verbose=false)
    try
        f("http://127.0.0.1:" * string(port))
    finally
        close(server)
    end
end
sse(d)= "data: " * canonical(d) * "\n\n"

@testset "SSE Unicode fragmentation, multiline and limits" begin
    d=SSEDecoder();result=Tuple{String,String}[]
    bytes=collect(codeunits(": comment\r\nevent: item\r\ndata: 中文\r\ndata: second\r\n\r\n"))
    for b in bytes;feed_sse!((event,data)->push!(result,(event,data)),d,[b]);end
    @test result==[("item","中文\nsecond")]
    finish_sse!((event,data)->push!(result,(event,data)),d)
    @test length(result)==1
    tiny=SSEDecoder(;max_bytes=8)
    @test_throws ShenScopeError feed_sse!((e,d)->nothing,tiny,collect(codeunits("data: too long")))
end

@testset "OpenAI-compatible real HTTP tool stream and native replay" begin
    mktempdir() do root
        captured=Dict{String,Any}[]
        wire=sse(Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("content"=>"中文","reasoning_content"=>"private",
            "tool_calls"=>[Dict("index"=>0,"id"=>"c1","function"=>Dict("name"=>"read","arguments"=>"{\"path\":"))]))])) *
            sse(Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("tool_calls"=>[Dict("index"=>0,"function"=>Dict("arguments"=>"\"f.py\"}"))]),"finish_reason"=>"tool_calls")])) *
            sse(Dict("choices"=>[],"usage"=>Dict("prompt_tokens"=>10,"completion_tokens"=>4))) * "data: [DONE]\n\n"
        mock_http(req->begin
            push!(captured,parsejson(String(req.body)))
            HTTP.Response(200,["Content-Type"=>"text/event-stream"],wire)
        end) do endpoint
            p=HTTPProvider(ProviderConfig(;endpoint,name="deepseek",model="model",retries=0))
            request=ModelRequest([Message(:user,"read")],Dict{String,Any}[],128,Dict{String,Any}())
            events=Tuple{Symbol,Any}[]
            result=stream_chat(p,request,(k,v)->push!(events,(k,v)),model_context(root))
            @test result.message.text=="中文"
            @test result.message.calls[1].arguments==Dict("path"=>"f.py")
            @test result.usage.input_tokens==10
            @test !any(e->e[1]==:text_delta && occursin("private",String(e[2])),events)
            follow=ModelRequest([result.message,Message(:tool,"{}";call_id="c1")],Dict{String,Any}[],128,Dict{String,Any}())
            @test prepare_request(p,follow).body["messages"][1]["reasoning_content"]=="private"
            other=HTTPProvider(ProviderConfig(;endpoint,name="other",model="other"))
            @test !haskey(prepare_request(other,follow).body["messages"][1],"reasoning_content")
            @test captured[1]["stream"]==true
        end
    end
end

@testset "Anthropic signature and tool continuation" begin
    mktempdir() do root
        frames=[Dict("type"=>"message_start","message"=>Dict("usage"=>Dict("input_tokens"=>9))),
            Dict("type"=>"content_block_start","index"=>0,"content_block"=>Dict("type"=>"thinking","thinking"=>"","signature"=>"")),
            Dict("type"=>"content_block_delta","index"=>0,"delta"=>Dict("type"=>"thinking_delta","thinking"=>"hidden")),
            Dict("type"=>"content_block_delta","index"=>0,"delta"=>Dict("type"=>"signature_delta","signature"=>"sig")),
            Dict("type"=>"content_block_start","index"=>1,"content_block"=>Dict("type"=>"tool_use","id"=>"a1","name"=>"read","input"=>Dict())),
            Dict("type"=>"content_block_delta","index"=>1,"delta"=>Dict("type"=>"input_json_delta","partial_json"=>"{\"path\":\"f\"}")),
            Dict("type"=>"message_delta","delta"=>Dict("stop_reason"=>"tool_use"),"usage"=>Dict("output_tokens"=>5)),
            Dict("type"=>"message_stop")]
        mock_http(req->HTTP.Response(200,join(sse.(frames)))) do endpoint
            p=HTTPProvider(ProviderConfig(;protocol=:anthropic,endpoint,retries=0))
            req=ModelRequest([Message(:system,"system"),Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}())
            result=stream_chat(p,req,(k,v)->nothing,model_context(root))
            @test result.message.calls[1].name=="read"
            @test isempty(result.message.text)
            @test result.usage.output_tokens==5
            next=prepare_request(p,ModelRequest([result.message,Message(:tool,"{}";call_id="a1")],Dict{String,Any}[],128,Dict{String,Any}()))
            @test next.body["messages"][1]["content"][1]["signature"]=="sig"
            @test next.body["messages"][2]["content"][1]["tool_use_id"]=="a1"
        end
    end
end

@testset "OpenAI Responses encrypted reasoning and call stream" begin
    mktempdir() do root
        frames=[Dict("type"=>"response.output_item.added","output_index"=>0,"item"=>Dict("type"=>"function_call","call_id"=>"r1","name"=>"search","arguments"=>"")),
            Dict("type"=>"response.function_call_arguments.delta","output_index"=>0,"delta"=>"{\"query\":\"x\"}"),
            Dict("type"=>"response.output_item.done","output_index"=>1,"item"=>Dict("type"=>"reasoning","id"=>"reason","encrypted_content"=>"opaque")),
            Dict("type"=>"response.completed","response"=>Dict("usage"=>Dict("input_tokens"=>12,"output_tokens"=>3)))]
        mock_http(req->HTTP.Response(200,join(sse.(frames)))) do endpoint
            p=HTTPProvider(ProviderConfig(;protocol=:openai_responses,endpoint,retries=0))
            result=stream_chat(p,ModelRequest([Message(:user,"find")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
            @test result.message.calls[1].arguments["query"]=="x"
            next=prepare_request(p,ModelRequest([result.message],Dict{String,Any}[],128,Dict{String,Any}()))
            @test any(i->get(i,"encrypted_content",nothing)=="opaque",next.body["input"])
            @test next.body["store"]==false
        end
    end
end

@testset "Gemini and Ollama native protocols" begin
    mktempdir() do root
        data=Dict("candidates"=>[Dict("content"=>Dict("parts"=>[
            Dict("text"=>"ready"),Dict("functionCall"=>Dict("name"=>"read","args"=>Dict("path"=>"f")),"thoughtSignature"=>"opaque")]),"finishReason"=>"STOP")],
            "usageMetadata"=>Dict("promptTokenCount"=>4,"candidatesTokenCount"=>2))
        mock_http(req->HTTP.Response(200,sse(data))) do endpoint
            p=HTTPProvider(ProviderConfig(;protocol=:gemini,endpoint,model="gemini-test",retries=0))
            result=stream_chat(p,ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
            @test result.message.text=="ready"
            @test result.message.calls[1].name=="read"
            next=prepare_request(p,ModelRequest([result.message],Dict{String,Any}[],128,Dict{String,Any}()))
            @test next.body["contents"][1]["parts"][2]["thoughtSignature"]=="opaque"
        end
        ollama=canonical(Dict("message"=>Dict("content"=>"local"),"done"=>false))*"\n" *
            canonical(Dict("message"=>Dict("content"=>""),"done"=>true,"prompt_eval_count"=>3,"eval_count"=>1))*"\n"
        mock_http(req->HTTP.Response(200,ollama)) do endpoint
            p=HTTPProvider(ProviderConfig(;protocol=:ollama,endpoint,retries=0))
            result=stream_chat(p,ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
            @test result.message.text=="local"
            @test result.usage.input_tokens==3
        end
    end
end

@testset "Retry before delivery, no replay after delivery, malformed calls" begin
    mktempdir() do root
        count=Ref(0)
        mock_http(req->begin
            count[]+=1
            count[]==1 ? HTTP.Response(429,"rate limited") : HTTP.Response(200,sse(Dict("choices"=>[Dict("delta"=>Dict("content"=>"ok"),"finish_reason"=>"stop")])) * "data: [DONE]\n\n")
        end) do endpoint
            p=HTTPProvider(ProviderConfig(;endpoint,retries=1))
            result=stream_chat(p,ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
            @test result.message.text=="ok"
            @test count[]==2
        end
        count[]=0
        mock_http(req->begin
            count[]+=1
            HTTP.Response(200,sse(Dict("choices"=>[Dict("delta"=>Dict("content"=>"partial"))])))
        end) do endpoint
            p=HTTPProvider(ProviderConfig(;endpoint,retries=2))
            @test_throws ShenScopeError stream_chat(p,ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
            @test count[]==1
        end
        wire=sse(Dict("choices"=>[Dict("delta"=>Dict("tool_calls"=>[Dict("index"=>0,"id"=>"bad","function"=>Dict("name"=>"edit","arguments"=>"{truncated"))]),"finish_reason"=>"tool_calls")]))
        mock_http(req->HTTP.Response(200,wire)) do endpoint
            p=HTTPProvider(ProviderConfig(;endpoint,retries=0))
            @test_throws ShenScopeError stream_chat(p,ModelRequest([Message(:user,"task")],Dict{String,Any}[],128,Dict{String,Any}()),(k,v)->nothing,model_context(root))
        end
    end
end
