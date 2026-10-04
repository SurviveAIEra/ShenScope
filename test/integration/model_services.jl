@testset "Real model catalog protocols snapshot credentials and confine every page" begin
    for protocol in (:openai_chat,:openai_responses,:anthropic,:gemini,:ollama)
        mktempdir() do root
            captured = Tuple{String,String}[];secret = Ref("first-fixture-key");lookups = Ref(0)
            model_service_fixture(request->begin
                header = protocol == :anthropic ? "x-api-key" : protocol == :gemini ? "x-goog-api-key" : "Authorization"
                push!(captured,(String(request.target),HTTP.header(request,header,"")))
                if length(captured) == 1
                    secret[] = "changed-fixture-key"
                    data = protocol == :ollama ? Dict("models"=>[Dict("name"=>"one"),Dict("name"=>"two")]) :
                        protocol == :gemini ? Dict("models"=>[Dict("name"=>"models/one")],"nextPageToken"=>"cursor id") :
                        Dict("data"=>[Dict("id"=>"one")],"has_more"=>true,"last_id"=>"cursor id")
                else
                    query = HTTP.URIs.queryparams(HTTP.URI(request.target))
                    field = protocol == :anthropic ? "after_id" : protocol == :gemini ? "pageToken" : "after"
                    @test query[field] == "cursor id"
                    data = protocol == :gemini ? Dict("models"=>[Dict("name"=>"models/two")]) : Dict("data"=>[Dict("id"=>"two")],"has_more"=>false)
                end
                HTTP.Response(200,["Content-Type"=>"application/json","ETag"=>"\"page\""],canonical(data))
            end) do endpoint
                provider = HTTPProvider(ProviderConfig(;protocol,endpoint,model="active",retries=0),key->(lookups[]+=1;secret[]))
                manager = ModelCatalogManager();ctx = model_context(root)
                result = refresh_model_catalog!(manager,provider,ctx)
                @test [model["id"] for model in result["models"]] == ["one","two"]
                @test result["pages"] == (protocol == :ollama ? 1 : 2)
                @test lookups[] == 1
                expected = protocol in (:anthropic,:gemini) ? "first-fixture-key" : "Bearer first-fixture-key"
                @test all(value[2] == expected for value in captured)
                @test all(startswith(value[1],protocol == :ollama ? "/api/tags" : "/models") for value in captured)
                view = model_catalog_view(manager,provider,ctx)
                @test !view["access_verified"] && isempty(view["models"])
                foreign = RuntimeContext(root;state_dir=ctx.state_dir,session_id="other",permissions=ctx.permissions)
                @test model_catalog_view(manager,provider,foreign)["total"] == 0
                @test all(model["features"]["tools"] === nothing for model in result["models"])
                snapshot = only(values(manager.snapshots))
                @test protocol == :ollama || snapshot.etag === nothing
                @test !occursin("fixture-key",canonical(result))
                cleanup = ShenScope.cleanup_model_catalogs!(manager)
                @test cleanup === nothing && isempty(manager.running) && isempty(manager.snapshots)
            end
        end
    end
end

@testset "Catalog TTL, ETag validation, failure preservation, ownership and cancellation" begin
    mktempdir() do root
        calls = Ref(0);phase = Ref(:first);seen_headers = String[]
        model_service_fixture(request->begin
            calls[] += 1;push!(seen_headers,HTTP.header(request,"If-None-Match",""))
            phase[] == :first && return HTTP.Response(200,["Content-Type"=>"application/json","ETag"=>"\"stable\""],canonical(Dict("data"=>[Dict("id"=>"cached")])) )
            phase[] == :not_modified && return HTTP.Response(304,["ETag"=>"\"stable\""],"")
            phase[] == :bad && return HTTP.Response(200,["Content-Type"=>"application/json"],"{malformed")
            phase[] == :loop && return HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict("data"=>[Dict("id"=>"cached")],"has_more"=>true,"last_id"=>"same")))
            HTTP.Response(500,["Content-Type"=>"application/json"],canonical(Dict("private"=>"PRIVATE ERROR FIXTURE")))
        end) do endpoint
            provider = HTTPProvider(ProviderConfig(;endpoint,model="active",retries=0))
            manager = ModelCatalogManager();ctx = model_context(root)
            first = refresh_model_catalog!(manager,provider,ctx)
            @test !first["cache_hit"] && calls[] == 1
            @test refresh_model_catalog!(manager,provider,ctx)["cache_hit"] && calls[] == 1
            phase[] = :not_modified
            second = refresh_model_catalog!(manager,provider,ctx;force=true)
            @test second["not_modified"] && second["revision"] == first["revision"]+1
            @test second["content_sha256"] == first["content_sha256"] && seen_headers[end] == "\"stable\""
            phase[] = :bad
            @test_throws ShenScopeError refresh_model_catalog!(manager,provider,ctx;force=true)
            @test model_catalog_view(manager,provider,ctx)["revision"] == second["revision"]
            @test model_catalog_view(manager,provider,ctx)["models"][1]["id"] == "cached"
            phase[] = :loop
            @test_throws ShenScopeError refresh_model_catalog!(manager,provider,ctx;force=true)
            @test model_catalog_view(manager,provider,ctx)["revision"] == second["revision"]
            phase[] = :error
            error = try refresh_model_catalog!(manager,provider,ctx;force=true);nothing catch cause;cause end
            @test error isa ShenScopeError && error.code == :server
            @test !occursin("PRIVATE ERROR",error.message)
            @test isempty(manager.running)
            @test ShenScope.forget_model_catalog!(manager,provider,ctx)["cleared"]
            @test isempty(manager.epochs) && model_catalog_view(manager,provider,ctx)["total"] == 0
            ShenScope.cleanup_model_catalogs!(manager)
            @test_throws ShenScopeError refresh_model_catalog!(manager,provider,ctx)
        end
    end
end

@testset "Real provider token-count bodies preserve actual input and one credential snapshot" begin
    for protocol in (:anthropic,:gemini)
        mktempdir() do root
            received = Dict{String,Any}[];headers = String[];key = Ref("count-first-fixture");lookups = Ref(0)
            model_service_fixture(request->begin
                push!(received,parsejson(String(request.body)))
                push!(headers,HTTP.header(request,protocol == :anthropic ? "x-api-key" : "x-goog-api-key",""))
                @test endswith(request.target,protocol == :anthropic ? "/messages/count_tokens" : "/models/active:countTokens")
                field = protocol == :anthropic ? "input_tokens" : "totalTokens"
                HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict(field=>37)))
            end) do endpoint
                provider = HTTPProvider(ProviderConfig(;protocol,endpoint,model="active",name="count",retries=0),name->(lookups[]+=1;key[]))
                ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:network=>Ask)),
                    approve=request->(key[]="count-rotated-fixture";:once))
                request = ModelRequest([Message(:system,"System 中文"),Message(:user,"Count 中😀")],
                    [Dict("name"=>"read","description"=>"Read file","parameters"=>Dict("type"=>"object"))],64,Dict{String,Any}())
                result = count_model_tokens(provider,request,ctx;mode=:provider)
                @test result["source"] == "provider_api" && result["input_tokens"] == 37
                @test !result["count_is_inference_usage"] && !result["tokenizer_verified"]
                @test result["within_configured_capacity"] && result["requested_output"] == 64
                @test lookups[] == 1 && only(headers) == "count-first-fixture"
                body = only(received)
                if protocol == :anthropic
                    @test Set(keys(body)) == Set(["model","messages","system","tools"])
                    @test body["messages"][1]["content"][1]["text"] == "Count 中😀"
                    @test body["system"] == "System 中文" && body["tools"][1]["input_schema"]["type"] == "object"
                else
                    generated = body["generateContentRequest"]
                    @test generated["model"] == "models/active"
                    @test generated["contents"][1]["parts"][1]["text"] == "Count 中😀"
                    @test generated["systemInstruction"]["parts"][1]["text"] == "System 中文"
                    @test generated["tools"][1]["functionDeclarations"][1]["name"] == "read"
                end
                @test !occursin("count-first-fixture",canonical(result))
            end
        end
    end
end

@testset "Token-count API does not hide authentication, malformed counts or missing endpoints" begin
    mktempdir() do root
        phase = Ref(:missing)
        model_service_fixture(request->begin
            status = phase[] == :missing ? 404 : phase[] == :auth ? 401 : 200
            value = phase[] == :boolean ? true : phase[] == :negative ? -1 : 3
            HTTP.Response(status,["Content-Type"=>"application/json"],canonical(Dict("input_tokens"=>value)))
        end) do endpoint
            provider = HTTPProvider(ProviderConfig(;protocol=:anthropic,endpoint,retries=0))
            request = ModelRequest([Message(:user,"Count")],Dict{String,Any}[],64,Dict{String,Any}())
            ctx = model_context(root)
            auto = count_model_tokens(provider,request,ctx;mode=:auto)
            @test auto["source"] == "estimate" && occursin("404",auto["fallback_reason"])
            @test_throws ShenScopeError count_model_tokens(provider,request,ctx;mode=:provider)
            phase[] = :auth
            error = try count_model_tokens(provider,request,ctx;mode=:auto);nothing catch cause;cause end
            @test error isa ShenScopeError && error.code == :authentication
            for invalid in (:boolean,:negative)
                phase[] = invalid
                @test_throws ShenScopeError count_model_tokens(provider,request,ctx;mode=:auto)
            end
        end
    end
end
