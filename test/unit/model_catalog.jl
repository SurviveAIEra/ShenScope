@testset "Provider catalog fields preserve unknowns, provenance and conflicting IDs" begin
    for protocol in (:openai_chat,:openai_responses,:anthropic)
        provider = HTTPProvider(ProviderConfig(;protocol,endpoint="http://127.0.0.1:1",model="active"))
        raw = Dict("data"=>[Dict("id"=>"unknown-tools"),Dict("id"=>"declared","context_window"=>9000,"max_output_tokens"=>1000,"capabilities"=>Dict("tools"=>false))])
        page = ShenScope.parse_catalog_page(provider,raw)
        @test isempty(page.diagnostics) && length(page.models) == 2
        @test page.models[1].features["tools"] === nothing
        @test page.models[1].context_window === nothing && isempty(page.models[1].operations)
        @test page.models[2].features["tools"] === false
        @test page.models[2].provenance["context_window"] == "provider_api"
        conflicting = ShenScope.parse_catalog_page(provider,Dict("data"=>[Dict("id"=>"declared","capabilities"=>Dict("tools"=>1))]))
        models = Dict(model.id=>model for model in page.models);invalid = Set{String}();diagnostics = ShenScope.CatalogDiagnostic[]
        ShenScope.merge_catalog_page!(models,invalid,diagnostics,conflicting)
        @test !haskey(models,"declared") && "declared" in invalid
        duplicate = ShenScope.parse_catalog_page(provider,Dict("data"=>[Dict("id"=>"unknown-tools")]))
        ShenScope.merge_catalog_page!(models,invalid,diagnostics,duplicate)
        @test isempty(models) && any(value -> value.code == :duplicate,diagnostics)
        @test_throws ShenScopeError ShenScope.parse_catalog_page(provider,Dict("data"=>Any[],"has_more"=>true))
        @test_throws ShenScopeError ShenScope.parse_catalog_page(provider,Dict("data"=>Any[],"has_more"=>1))
        @test_throws ShenScopeError ShenScope.parse_catalog_page(provider,Dict("data"=>[Dict("id"=>string(i)) for i in 1:1025]))
    end
    gemini = HTTPProvider(ProviderConfig(;protocol=:gemini,endpoint="http://127.0.0.1:1",model="active"))
    page = ShenScope.parse_catalog_page(gemini,Dict("models"=>[Dict("name"=>"models/chat","displayName"=>"Chat 中文",
        "inputTokenLimit"=>9000,"outputTokenLimit"=>1000,"supportedGenerationMethods"=>["generateContent","countTokens"])],"nextPageToken"=>"next/ ?"))
    @test page.models[1].id == "chat" && page.models[1].name == "Chat 中文"
    @test page.models[1].max_input == 9000 && page.models[1].context_window === nothing
    @test page.models[1].operations == ["chat","count_tokens"] && page.models[1].features["vision"] === nothing
    @test page.cursor == "next/ ?"
    invalid_namespace = ShenScope.parse_catalog_page(gemini,Dict("models"=>[Dict("name"=>"projects/foreign")]))
    @test isempty(invalid_namespace.models) && length(invalid_namespace.diagnostics) == 1
    ollama = HTTPProvider(ProviderConfig(;protocol=:ollama,endpoint="http://127.0.0.1:1",model="active"))
    local_page = ShenScope.parse_catalog_page(ollama,Dict("models"=>[Dict("name"=>"local:latest","details"=>Dict("parameter_size"=>"8B"))]))
    @test local_page.models[1].id == "local:latest" && local_page.models[1].context_window === nothing
    @test local_page.models[1].features["tools"] === nothing && local_page.cursor === nothing
    @test_throws ShenScopeError ShenScope.catalog_source_id(HTTPProvider(ProviderConfig(;endpoint="https://example.test/v1?credential=fixture")))
    @test_throws ShenScopeError ShenScope.model_descriptor("x","x",repeat("a",64),:openai_chat;context_window=1024,max_output=1024)
    @test_throws ShenScopeError ShenScope.model_descriptor("x","x",repeat("a",64),:openai_chat;features=Dict("tools"=>1))
end

@testset "Token-count inputs validate roles/tools and estimate without reading credentials" begin
    mktempdir() do root
        lookups = Ref(0)
        provider = HTTPProvider(ProviderConfig(;endpoint="http://127.0.0.1:1"),key->(lookups[]+=1;"private-fixture"))
        request = model_request_from_dict(Dict("messages"=>[Dict("role"=>"user","text"=>"English 中文😀")],"max_output"=>64))
        result = count_model_tokens(provider,request,model_context(root);mode=:estimate)
        @test result["source"] == "estimate" && !result["tokenizer_verified"] && !result["count_is_inference_usage"]
        @test result["input_tokens"] > 0 && result["within_configured_capacity"]
        @test lookups[] == 0
        @test_throws ShenScopeError count_model_tokens(provider,request,model_context(root);mode=:provider)
        @test_throws ShenScopeError model_request_from_dict(Dict("messages"=>[Dict("role"=>"tool","text"=>"{}")]))
        @test_throws ShenScopeError model_request_from_dict(Dict("messages"=>[Dict("role"=>"developer","text"=>"x")]))
        @test_throws ShenScopeError model_request_from_dict(Dict("messages"=>Any[],"max_output"=>true))
        @test_throws ShenScopeError model_request_from_dict(Dict("messages"=>Any[],"unknown"=>1))
        schema = Dict("name"=>"read","description"=>"Read","parameters"=>Dict("type"=>"object"))
        @test_throws ShenScopeError model_request_from_dict(Dict("messages"=>Any[],"tools"=>[schema,schema]))
        tool_request = model_request_from_dict(Dict("messages"=>[Dict("role"=>"assistant","text"=>"","calls"=>
            [Dict("id"=>"call","name"=>"read","arguments"=>Dict("path"=>"src.jl"))]),
            Dict("role"=>"tool","call_id"=>"call","text"=>"{}")],"tools"=>[schema]))
        @test tool_request.messages[1].calls[1].arguments["path"] == "src.jl"
        @test tool_request.messages[2].call_id == "call"
        tiny = HTTPProvider(ProviderConfig(;endpoint="http://127.0.0.1:1",capabilities=ModelCapabilities(;context_window=128,max_output=64)))
        oversized = ModelRequest([Message(:user,repeat("x",500))],Dict{String,Any}[],64,Dict{String,Any}())
        @test !count_model_tokens(tiny,oversized,model_context(root);mode=:estimate)["within_configured_capacity"]
    end
end
