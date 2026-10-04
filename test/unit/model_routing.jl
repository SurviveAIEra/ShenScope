@testset "Model routing config is strict, bounded, immutable and credential blind" begin
    reads = Ref(0);config = routing_fixture_config()
    fleet = model_routing_from_config(config;credential_lookup=key->(reads[]+=1;"fixture credential"))
    @test reads[] == 0
    @test fleet.default_role == "main" && length(fleet.providers) == 2 && length(fleet.profiles) == 3
    config["model_routing"]["profiles"]["writer"]["options"]["temperature"] = 0.9
    @test parsejson(fleet.profiles["writer"].selection.options_json)["temperature"] == 0.2
    @test fleet.providers["primary"].runtime.circuits === fleet.providers["backup"].runtime.circuits
    @test !occursin("fixture credential",repr(fleet))
    @test !occursin("fixture credential",repr(fleet.profiles["writer"].selection))
    @test_throws ShenScopeError RoutedProvider(fleet;role="missing")
    @test_throws ShenScopeError RoutedProvider(fleet,"missing")
    invalid = Function[
        d->(d["extra"]=true),d->(d["default_role"]="missing"),d->(d["providers"]=Dict()),
        d->(d["providers"]["primary"]["unknown"]=1),d->delete!(d["providers"]["primary"],"key_env"),
        d->(d["providers"]["primary"]["timeout"]=true),d->(d["providers"]["primary"]["input_price"]=true),
        d->(d["profiles"]["writer"]["provider"]="missing"),d->(d["profiles"]["writer"]["model"]=" "),
        d->(d["profiles"]["writer"]["options"]=Dict("model"=>"overridden")),
        d->(d["profiles"]["writer"]["options"]=Dict("api_key"=>"fixture secret")),
        d->(d["profiles"]["writer"]["options"]=Dict("apiKey"=>"fixture secret")),
        d->(d["profiles"]["writer"]["options"]=Dict("items"=>[Dict("access_token"=>"fixture secret")])),
        d->(d["profiles"]["writer"]["options"]=Dict("headers"=>Dict("Authorization"=>"fixture secret"))),
        d->(d["profiles"]["writer"]["options"]=Dict("bearer-token"=>"fixture secret")),
        d->(d["profiles"]["writer"]["options"]=Dict("value"=>Inf)),
        d->(d["profiles"]["writer"]["capabilities"]=Dict("max_output"=>true)),
        d->(d["profiles"]["writer"]["capabilities"]=Dict("tools"=>"yes")),
        d->(d["profiles"]["writer"]["capabilities"]=Dict("context_window"=>20,"max_output"=>20)),
        d->(d["roles"]["main"]["profiles"]=["writer","writer"]),
        d->(d["roles"]["main"]["profiles"]=["missing"]),
        d->(d["roles"]["main"]["profiles"]=fill("writer",9)),
        d->(d["roles"]["main"]["fallback_codes"]=["authentication"]),
        d->(d["roles"]["main"]["fallback_codes"]=["server","server"]),
        d->(d["providers"]["backup"]=deepcopy(d["providers"]["primary"]))]
    for mutate in invalid
        candidate = routing_fixture_config();mutate(candidate["model_routing"])
        @test_throws ShenScopeError model_routing_from_config(candidate;credential_lookup=key->error("must not read key"))
    end
    @test reads[] == 0
    close_model_fleet!(fleet)
    @test_throws ShenScopeError RoutedProvider(fleet)
end

@testset "Route plans explain feature, capacity and native replay exclusions without keys" begin
    config = routing_fixture_config();config["model_routing"]["profiles"]["backup"]["capabilities"] =
        Dict("tools"=>false,"context_window"=>4096,"max_output"=>128)
    fleet = model_routing_from_config(config;credential_lookup=key->error("planning cannot read keys"))
    route = RoutedProvider(fleet);request = routing_request(options=Dict{String,Any}("temperature"=>0.7))
    plan = model_route_plan(route,request)
    @test [candidate.profile_id for candidate in plan.candidates] == ["writer","backup"]
    @test plan.candidates[1].request.options["temperature"] == 0.7
    @test capabilities(route).context_window == 4096 && capabilities(route).max_output == 128
    @test capabilities(route).tools
    request.options["temperature"] = 0.99
    @test plan.candidates[1].request.options["temperature"] == 0.7
    report = model_route_plan_dict(plan)
    @test !report["credential_lookup_performed"] && !report["network_request_performed"]
    schema = Dict{String,Any}("name"=>"read","description"=>"read file","parameters"=>Dict("type"=>"object"))
    tools_plan = model_route_plan(route,routing_request(tools=[schema]))
    @test length(tools_plan.candidates) == 1 && tools_plan.excluded[1]["code"] == "capability"
    output_plan = model_route_plan(route,routing_request(max_output=129))
    @test length(output_plan.candidates) == 1 && output_plan.excluded[1]["code"] == "capability"
    structured = model_route_plan(route,routing_request(options=Dict{String,Any}("response_format"=>Dict("type"=>"json_object"))))
    @test isempty(structured.candidates) && all(row->row["code"] == "capability",structured.excluded)
    @test_throws ShenScopeError ShenScope.validate_request(route,routing_request(options=Dict{String,Any}("reasoning_effort"=>"high")))
    source = plan.candidates[1].provider
    native = Dict{String,Any}("identity"=>ShenScope.model_wire_identity(source.config),
        "source_id"=>ShenScope.catalog_source_id(source),"reasoning_content"=>"opaque reasoning fixture")
    replay = ModelRequest([Message(:assistant,"previous";native),Message(:user,"continue")],Dict{String,Any}[],64,Dict{String,Any}())
    replay_plan = model_route_plan(route,replay)
    @test [value.profile_id for value in replay_plan.candidates] == ["writer"]
    @test replay_plan.excluded[1]["code"] == "native_replay_model_mismatch"
    delete!(native,"source_id");legacy = ModelRequest([Message(:assistant,"legacy";native)],Dict{String,Any}[],64,Dict{String,Any}())
    @test model_route_plan(route,legacy).excluded[1]["code"] == "native_replay_scope_unknown"
    invalid = ModelRequest([Message(:assistant,"invalid";native=Dict("parts"=>true))],Dict{String,Any}[],64,Dict{String,Any}())
    @test all(value->value["code"] == "native_replay_invalid",model_route_plan(route,invalid).excluded)
    close_model_fleet!(fleet)
end

@testset "Routing receipts and runtime seats retain strict conversation ownership" begin
    mktempdir() do root
        fleet = model_routing_from_config(routing_fixture_config());ctx = model_context(root)
        sibling = RuntimeContext(root;state_dir=ctx.state_dir,session_id="sibling")
        id = ShenScope.begin_model_route!(fleet,ctx)
        @test model_fleet_metadata(fleet,ctx)["in_flight"] == 1
        @test model_fleet_metadata(fleet,sibling)["in_flight"] == 0
        @test_throws ShenScopeError close_model_fleet!(fleet)
        @test_throws ShenScopeError ShenScope.finish_model_route!(fleet,id,sibling,Dict("id"=>id))
        @test length(fleet.active) == 1
        ShenScope.finish_model_route!(fleet,id,ctx,Dict("id"=>id,"outcome"=>"success"))
        @test length(model_fleet_metadata(fleet,ctx)["recent_requests"]) == 1
        @test isempty(model_fleet_metadata(fleet,sibling)["recent_requests"])
        report = model_fleet_metadata(fleet,ctx);report["recent_requests"][1]["outcome"]="mutated"
        @test model_fleet_metadata(fleet,ctx)["recent_requests"][1]["outcome"] == "success"
        fleet.max_history=2
        for i in 1:3
            receipt_id=ShenScope.begin_model_route!(fleet,ctx)
            ShenScope.finish_model_route!(fleet,receipt_id,ctx,Dict("id"=>receipt_id,"number"=>i))
        end
        @test [value["number"] for value in model_fleet_metadata(fleet,ctx)["recent_requests"]] == [2,3]
        fleet.max_active=1;active = ShenScope.begin_model_route!(fleet,ctx)
        @test_throws ShenScopeError ShenScope.begin_model_route!(fleet,sibling)
        ShenScope.finish_model_route!(fleet,active,ctx,Dict("id"=>active))
        @test isempty(fleet.active)
        close_model_fleet!(fleet)
    end
end
