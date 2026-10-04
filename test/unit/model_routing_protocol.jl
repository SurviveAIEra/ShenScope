@testset "Routing RPC, default/worker roles, profile services and config validation share one fleet" begin
    mktempdir() do root
        network_calls=Ref(0)
        model_service_fixture(request->begin
            network_calls[]+=1
            HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict("data"=>[Dict("id"=>"directory-model")])) )
        end) do endpoint
            config=routing_fixture_config(endpoint,endpoint)
            config["permissions"]["network"]="allow";config["permissions"]["persistence"]="allow"
            path=joinpath(root,"routing.toml");save_config!(config;path)
            server=CoreServer(root;config_file=path,state_dir=joinpath(root,"state"),output=IOBuffer())
            try
                dispatch_rpc(server,"initialize",Dict())
                model=ShenScope.server_models_tool(server);main=server.provider_factory(server)
                worker=ShenScope.server_task_tool(server).manager.executor.provider_factory(model_context(root))
                @test main isa RoutedProvider && main.role == "main" && main.fleet === model.fleet
                @test worker isa RoutedProvider && worker.role == "worker" && worker.fleet === main.fleet
                owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
                foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
                view=dispatch_rpc(server,"models/query",Dict("session_id"=>owner))
                @test view["catalog"]["configured"]["id"] == "writer-model" && view["routing"]["enabled"]
                @test network_calls[] == 0
                view=dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"profile"=>"backup"))
                @test view["catalog"]["configured"]["id"] == "backup-model" && view["status"]["provider"] == "second-source"
                @test_throws ShenScopeError dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"profile"=>"missing"))
                @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"no side effects","model_role"=>"missing"))
                @test isempty(server.runs) && network_calls[] == 0
                plan=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"plan","role"=>"worker",
                    "request"=>Dict("messages"=>[Dict("role"=>"user","text"=>"worker preview")],"max_output"=>32)))
                job=await_model_job(server,plan["job_id"])
                @test job.status == :complete && only(job.result["eligible"])["model"] == "worker-model"
                @test network_calls[] == 0
                refresh=dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"profile"=>"backup","action"=>"refresh"))
                @test await_model_job(server,refresh["job_id"]).status == :complete && network_calls[] == 1
                @test dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"profile"=>"backup"))["catalog"]["total"] == 1
                @test dispatch_rpc(server,"models/query",Dict("session_id"=>foreign,"profile"=>"backup"))["catalog"]["total"] == 0
                ctx=server.contexts[owner];id=ShenScope.begin_model_route!(model.fleet,ctx)
                ShenScope.finish_model_route!(model.fleet,id,ctx,Dict("id"=>id,"outcome"=>"success"))
                @test length(dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["routing"]["recent_requests"]) == 1
                @test isempty(dispatch_rpc(server,"models/query",Dict("session_id"=>foreign))["routing"]["recent_requests"])
                before=read(path,String);invalid=deepcopy(config)
                invalid["model_routing"]["roles"]["main"]["profiles"]=["missing"]
                @test_throws ShenScopeError save_config!(invalid;path)
                @test read(path,String) == before
                prior=model.fleet;next=dispatch_rpc(server,"config/get",Dict())
                @test haskey(dispatch_rpc(server,"config/set",Dict("value"=>next["value"],"expected_sha256"=>next["sha256"])),"sha256")
                @test prior.closed && model.fleet !== prior && !model.fleet.closed
                @test server.provider_factory(server).fleet === model.fleet
                @test ShenScope.server_task_tool(server).manager.executor.provider_factory(ctx).fleet === model.fleet
            finally
                stop_server!(server)
            end
            @test ShenScope.server_models_tool(server).fleet.closed
        end
    end
end
