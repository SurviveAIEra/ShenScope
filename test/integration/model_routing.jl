@testset "Explicit routing fixes every eligible key before approval and records real source fallback" begin
    mktempdir() do root
        first_calls=Ref(0);backup_calls=Ref(0);keys=Dict("FIRST_ROUTE_KEY"=>"first-fixture-before","BACKUP_ROUTE_KEY"=>"backup-fixture-before")
        headers=String[];bodies=Dict{String,Any}[];lookups=Ref(0);events=AgentEvent[]
        model_service_fixture(request->begin
            first_calls[]+=1;push!(headers,HTTP.header(request,"Authorization",""));push!(bodies,parsejson(request.body))
            HTTP.Response(503,["Content-Type"=>"application/json"],"{\"error\":\"PRIVATE FAILURE FIXTURE\"}")
        end) do first_endpoint
            model_service_fixture(request->begin
                backup_calls[]+=1;push!(headers,HTTP.header(request,"Authorization",""));push!(bodies,parsejson(request.body))
                routing_chat_response("fallback complete 中文")
            end) do backup_endpoint
                request=routing_request(options=Dict{String,Any}("temperature"=>0.6))
                config=routing_fixture_config(first_endpoint,backup_endpoint)
                fleet=model_routing_from_config(config;credential_lookup=key->(lookups[]+=1;keys[key]))
                approvals=Ref(0)
                ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(:network=>Ask,:read=>Allow)),
                    approve=permission->begin
                        approvals[]+=1;keys["FIRST_ROUTE_KEY"]="first-fixture-after";keys["BACKUP_ROUTE_KEY"]="backup-fixture-after"
                        request.options["temperature"]=0.9;:once
                    end,sink=event->push!(events,event))
                result=stream_chat(RoutedProvider(fleet),request,(kind,payload)->nothing,ctx)
                @test result.message.text == "fallback complete 中文"
                @test lookups[] == 2 && approvals[] == 2
                @test headers == ["Bearer first-fixture-before","Bearer backup-fixture-before"]
                @test all(body->body["temperature"] == 0.6,bodies)
                @test [body["model"] for body in bodies] == ["writer-model","backup-model"]
                @test result.message.native["route"]["profile"] == "backup"
                @test result.message.native["source_id"] == ShenScope.catalog_source_id(fleet.providers["backup"])
                @test count(event->event.kind == :model_route_selected,events) == 2
                @test only(filter(event->event.kind == :model_route_fallback,events)).payload["code"] == "server"
                report=model_fleet_metadata(fleet,ctx);receipt=only(report["recent_requests"])
                @test receipt["outcome"] == "success" && receipt["selected_profile"] == "backup" && receipt["delivered"]
                @test length(receipt["attempts"]) == 2 && receipt["attempts"][1]["code"] == "server"
                @test !occursin("fixture-before",canonical(report)) && !occursin("PRIVATE FAILURE",canonical(report))
                @test isempty(fleet.active) && sum(length(entry.leases) for entry in values(fleet.circuits.entries)) == 0
                keys["FIRST_ROUTE_KEY"]="first-fixture-before";keys["BACKUP_ROUTE_KEY"]="backup-fixture-before"
                result=stream_chat(RoutedProvider(fleet),routing_request(),(kind,payload)->nothing,ctx)
                @test result.message.text == "fallback complete 中文" && first_calls[] == 1 && backup_calls[] == 2
                last_receipt=last(model_fleet_metadata(fleet,ctx)["recent_requests"])
                @test last_receipt["attempts"][1]["code"] == "circuit_open"
                stream_chat(RoutedProvider(fleet),routing_request(),(kind,payload)->nothing,ctx)
                @test first_calls[] == 2 && backup_calls[] == 3
                @test last(model_fleet_metadata(fleet,ctx)["recent_requests"])["attempts"][1]["code"] == "server"
                close_model_fleet!(fleet)
            end
        end
    end
end

@testset "Terminal, partial, consumer and explicit fallback restrictions prevent source switching" begin
    for mode in (:auth,:partial,:consumer,:fallback_disabled,:event_consumer)
        mktempdir() do root
            first_calls=Ref(0);backup_calls=Ref(0)
            model_service_fixture(request->begin
                first_calls[]+=1
                mode in (:auth,:fallback_disabled) && return HTTP.Response(mode == :auth ? 401 : 503,[],"{}")
                mode == :partial && return HTTP.Response(200,["Content-Type"=>"text/event-stream"],
                    "data: "*canonical(Dict("choices"=>[Dict("delta"=>Dict("content"=>"partial fixture"))]))*"\n\n")
                routing_chat_response()
            end) do first_endpoint
                model_service_fixture(request->(backup_calls[]+=1;routing_chat_response())) do backup_endpoint
                    config=routing_fixture_config(first_endpoint,backup_endpoint)
                    mode == :fallback_disabled && (config["model_routing"]["roles"]["main"]["fallback_codes"]=String[])
                    fleet=model_routing_from_config(config;credential_lookup=key->"fixture-key")
                    ctx=model_context(root)
                    mode == :event_consumer && (ctx.sink=event->event.kind == :model_route_selected ? error("broken fixture consumer") : nothing)
                    sink=mode == :consumer ? (kind,payload)->error("broken fixture consumer") : (kind,payload)->nothing
                    failure=try stream_chat(RoutedProvider(fleet),routing_request(),sink,ctx);nothing catch error;error end
                    @test failure isa ShenScopeError
                    @test failure.code == (mode == :auth ? :authentication : mode == :partial ? :stream_interrupted :
                        mode == :fallback_disabled ? :server : :delivery)
                    @test backup_calls[] == 0 && first_calls[] == (mode == :event_consumer ? 0 : 1)
                    @test isempty(fleet.active)
                    receipt=only(model_fleet_metadata(fleet,ctx)["recent_requests"])
                    @test receipt["outcome"] == "failed" && length(receipt["attempts"]) == 1
                    mode in (:partial,:consumer) && @test receipt["delivered"]
                    if mode == :consumer
                        entry=only(values(fleet.circuits.entries));@test entry.neutral_outcomes == 1 && entry.failures == 0
                    end
                    close_model_fleet!(fleet)
                end
            end
        end
    end
end

@testset "Route cancellation, admission and context cost accounting stop work before side effects" begin
    mktempdir() do root
        calls=Ref(0);keys=Ref(0)
        model_service_fixture(request->(calls[]+=1;routing_chat_response())) do endpoint
            config=routing_fixture_config(endpoint,endpoint)
            fleet=model_routing_from_config(config;credential_lookup=key->(keys[]+=1;"fixture-key"))
            ctx=model_context(root);fleet.max_active=1
            held=ShenScope.begin_model_route!(fleet,ctx)
            @test_throws ShenScopeError stream_chat(RoutedProvider(fleet),routing_request(),(kind,payload)->nothing,ctx)
            @test keys[] == 0 && calls[] == 0
            ShenScope.finish_model_route!(fleet,held,ctx,Dict("id"=>held))
            ctx.permissions.rules[:network]=Ask
            ctx.approve=permission->begin cancel!(ctx.cancellation);:once end
            @test_throws ShenScopeError stream_chat(RoutedProvider(fleet),routing_request(),(kind,payload)->nothing,ctx)
            @test keys[] == 2 && calls[] == 0 && isempty(fleet.active)
            close_model_fleet!(fleet)
            config["model_routing"]["providers"]["backup"]["input_price"]=1000.0
            config["model_routing"]["providers"]["backup"]["output_price"]=1000.0
            tool=ModelsTool(config;credential_lookup=key->(keys[]+=1;"fixture-key"))
            route=agent_model_provider(tool)
            @test model_price_bound(route) == (1000.0,1000.0)
            usage_ctx=RuntimeContext(root;state_dir=joinpath(root,"cost-state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:network=>Allow,:persistence=>Allow)),
                budget=BudgetLedger(BudgetLimits(;max_cost=0.01)))
            before=keys[]
            error=try run_agent!(route,"test conservative configured routing prices",usage_ctx;tools=AbstractTool[tool]);nothing catch error;error end
            @test error isa ShenScopeError && error.code == :budget
            @test calls[] == 0 && keys[] == before
            @test isempty(usage_ctx.budget.reservations) && isempty(tool.fleet.active)
            cleanup_models_tool!(tool)
        end
    end
end
