function retry_fixture_wire(text)
    "data: "*canonical(Dict("choices"=>[Dict("index"=>0,"delta"=>Dict("content"=>text),"finish_reason"=>"stop")]))*"\n\ndata: [DONE]\n\n"
end

function retry_fixture_provider(endpoint;retries=1,threshold=3,cooldown=0.1,maximum_delay=1.0,key_lookup=key->"",
        initial_delay=0.01)
    runtime = ModelProviderRuntime(;retry_policy=ModelRetryPolicy(;max_retries=retries,initial_delay,
        maximum_delay,jitter_ratio=0.0),circuit_policy=ModelCircuitPolicy(;failure_threshold=threshold,cooldown))
    HTTPProvider(ProviderConfig(;endpoint,retries=0,timeout=15.0),key_lookup;runtime)
end

@testset "Undelivered interrupted streams retry while delivered reasoning progress prevents replay" begin
    for mode in (:empty,:reasoning)
        mktempdir() do root
            calls=Ref(0);events=Tuple{Symbol,Any}[]
            model_service_fixture(request->begin
                calls[]+=1
                wire=calls[] > 1 ? retry_fixture_wire("after interruption") : mode == :empty ? "" :
                    "data: "*canonical(Dict("choices"=>[Dict("delta"=>Dict("reasoning_content"=>"opaque fixture"))]))*"\n\n"
                HTTP.Response(200,["Content-Type"=>"text/event-stream"],wire)
            end) do endpoint
                provider=retry_fixture_provider(endpoint;retries=1)
                request=ModelRequest([Message(:user,"Interrupted")],Dict{String,Any}[],64,Dict())
                if mode == :empty
                    @test stream_chat(provider,request,(kind,payload)->push!(events,(kind,payload)),model_context(root)).message.text == "after interruption"
                    @test calls[] == 2
                else
                    @test_throws ShenScopeError stream_chat(provider,request,(kind,payload)->push!(events,(kind,payload)),model_context(root))
                    @test calls[] == 1 && any(event->event[1] == :model_progress,events)
                end
            end
        end
    end
end

@testset "HTTP retries retain exact body/key snapshots and count one logical outcome" begin
    mktempdir() do root
        headers = String[];bodies = String[];calls = Ref(0);secret = Ref("retry-first-fixture");lookups = Ref(0)
        format = Dict{String,Any}("type"=>"json_schema","json_schema"=>Dict("name"=>"before"))
        model_service_fixture(request->begin
            calls[] += 1;push!(headers,HTTP.header(request,"Authorization",""));push!(bodies,String(request.body))
            if calls[] == 1
                secret[] = "retry-rotated-fixture";format["json_schema"]["name"] = "after"
                HTTP.Response(503,["Retry-After-Ms"=>"30","Content-Type"=>"application/json"],"{\"private\":\"RETRY PRIVATE DETAILS\"}")
            else
                HTTP.Response(200,["Content-Type"=>"text/event-stream"],retry_fixture_wire("retried 中文"))
            end
        end) do endpoint
            provider = retry_fixture_provider(endpoint;threshold=1,key_lookup=key->(lookups[]+=1;secret[]))
            events = AgentEvent[];ctx = model_context(root);ctx.sink=event->push!(events,event)
            request = ModelRequest([Message(:user,"Retry")],Dict{String,Any}[],64,Dict("response_format"=>format))
            result = stream_chat(provider,request,(kind,payload)->nothing,ctx)
            @test result.message.text == "retried 中文" && calls[] == 2
            @test bodies[1] == bodies[2] && parsejson(bodies[2])["response_format"]["json_schema"]["name"] == "before"
            @test headers == ["Bearer retry-first-fixture","Bearer retry-first-fixture"] && lookups[] == 1
            key = ShenScope.CredentialSnapshot("retry-first-fixture")
            health = model_health_snapshot(provider,ctx;credentials=key)
            @test health["state"] == "closed" && health["successes"] == 1 && health["failures"] == 0
            retry = only(filter(event->event.kind == :model_retry,events))
            @test retry.payload["server_advice_used"] && retry.payload["attempt"] == 1
            @test 0.0 <= retry.payload["delay_seconds"] <= 0.03
            @test !occursin("RETRY PRIVATE DETAILS",canonical([event.payload for event in events]))
            @test !occursin("retry-first-fixture",canonical(health))
        end
    end
end

@testset "Provider wait caps, terminal failures and server veto prevent extra HTTP attempts" begin
    for phase in (:too_long,:veto,:auth,:bad_input)
        mktempdir() do root
            calls = Ref(0)
            model_service_fixture(request->begin
                calls[] += 1
                status = phase == :auth ? 401 : phase == :bad_input ? 400 : 503
                headers = phase == :too_long ? ["Retry-After"=>"2"] : phase == :veto ? ["x-should-retry"=>"false"] : ["x-should-retry"=>"true"]
                HTTP.Response(status,headers,"private fixture body")
            end) do endpoint
                provider = retry_fixture_provider(endpoint;retries=2,maximum_delay=0.1)
                ctx = model_context(root);events=AgentEvent[];ctx.sink=event->push!(events,event)
                failure = try stream_chat(provider,ModelRequest([Message(:user,"Stop")],Dict{String,Any}[],64,Dict()),
                    (kind,payload)->nothing,ctx);nothing catch error;error end
                @test failure isa ShenScopeError && calls[] == 1
                @test failure.code == (phase == :auth ? :authentication : phase == :bad_input ? :request : :server)
                health = model_health_snapshot(provider,ctx)
                @test health["failures"] == (phase in (:auth,:bad_input) ? 0 : 1)
                @test health["neutral_outcomes"] == (phase in (:auth,:bad_input) ? 1 : 0)
                @test !occursin("private fixture body",failure.message)
                if phase in (:too_long,:veto)
                    reason = only(filter(event->event.kind == :model_retry_suppressed,events)).payload["reason"]
                    @test reason == (phase == :too_long ? "server_wait_exceeds_policy" : "server_declined")
                end
            end
        end
    end
end

@testset "Actual provider failures open circuits and the next explicit request performs one probe" begin
    mktempdir() do root
        calls=Ref(0);healthy=Ref(false)
        model_service_fixture(request->begin
            calls[]+=1
            healthy[] ? HTTP.Response(200,["Content-Type"=>"text/event-stream"],retry_fixture_wire("recovered")) : HTTP.Response(503,"down")
        end) do endpoint
            provider = retry_fixture_provider(endpoint;retries=0,threshold=1,cooldown=0.05)
            now=Ref(0.0);provider.runtime.circuits.clock=()->now[]
            ctx=model_context(root);request=ModelRequest([Message(:user,"Recover")],Dict{String,Any}[],64,Dict())
            @test_throws ShenScopeError stream_chat(provider,request,(kind,payload)->nothing,ctx)
            snapshot=model_health_snapshot(provider,ctx)
            @test snapshot["state"] == "open" && snapshot["failures"] == 1 && calls[] == 1
            # The injected clock advances only when this fixture chooses,
            # independently of compilation and actual loopback transport time.
            blocked=try stream_chat(provider,request,(kind,payload)->nothing,ctx);nothing catch error;error end
            @test blocked isa ShenScopeError && blocked.code == :circuit_open && calls[] == 1
            now[]=0.05;healthy[]=true
            @test stream_chat(provider,request,(kind,payload)->nothing,ctx).message.text == "recovered"
            final=model_health_snapshot(provider,ctx)
            @test final["state"] == "closed" && final["successes"] == 1 && calls[] == 2
            @test any(record->record["event"] == "recovered",final["history"])
        end
    end
end

@testset "Partial output and broken output consumers never cause replay or health misclassification" begin
    for mode in (:partial,:consumer)
        mktempdir() do root
            calls=Ref(0)
            model_service_fixture(request->begin
                calls[]+=1
                wire=mode == :partial ? "data: "*canonical(Dict("choices"=>[Dict("delta"=>Dict("content"=>"partial"))]))*"\n\n" : retry_fixture_wire("consumer")
                HTTP.Response(200,["Content-Type"=>"text/event-stream"],wire)
            end) do endpoint
                provider=retry_fixture_provider(endpoint;retries=3)
                ctx=model_context(root);sink=(kind,payload)->(mode == :consumer ? error("PRIVATE CONSUMER DETAILS") : nothing)
                failure=try stream_chat(provider,ModelRequest([Message(:user,"Output")],Dict{String,Any}[],64,Dict()),sink,ctx);nothing catch error;error end
                @test failure isa ShenScopeError && calls[] == 1
                @test failure.code == (mode == :partial ? :stream_interrupted : :delivery)
                @test model_health_snapshot(provider,ctx)["failures"] == (mode == :partial ? 1 : 0)
                @test !occursin("PRIVATE CONSUMER DETAILS",failure.message)
            end
        end
    end
end
