@testset "CLI role routing previews and explicit profile services stay local until inference" begin
    mktempdir() do root
        calls=Dict("first"=>0,"backup"=>0)
        model_service_fixture(request->begin
            calls["first"]+=1;HTTP.Response(503,[],"{}")
        end) do first_endpoint
            model_service_fixture(request->begin
                calls["backup"]+=1;routing_chat_response("CLI routed completion 中文")
            end) do backup_endpoint
                config=routing_fixture_config(first_endpoint,backup_endpoint)
                config["permissions"]["network"]="allow";config["permissions"]["persistence"]="allow"
                path=joinpath(root,"config.toml");save_config!(config;path)
                common=["--root",root,"--state-dir",joinpath(root,"cli-state"),"--config",path]
                status,value=captured_models_cli(["models","routes",common...],root)
                @test status == 0 && value["enabled"] && value["default_role"] == "main"
                input=joinpath(root,"request.json");write(input,canonical(Dict("messages"=>[Dict("role"=>"user","text"=>"local plan")],"max_output"=>32)))
                status,value=captured_models_cli(["models","plan",input,"--model-role","worker",common...],root)
                @test status == 0 && only(value["eligible"])["model"] == "worker-model"
                @test !value["credential_lookup_performed"] && !value["network_request_performed"]
                status,value=captured_models_cli(["models","status","--model-profile","backup",common...],root)
                @test status == 0 && value["configured"]["id"] == "backup-model"
                @test sum(values(calls)) == 0
                status,_=captured_models_cli(["models","status","--model-profile","missing",common...],root)
                @test status == 1 && sum(values(calls)) == 0
                output=joinpath(root,"chat-output.txt")
                status=open(output,"w") do stream
                    redirect_stdout(stream) do
                        ShenScope.main(["chat","Use the explicit main role",common...])
                    end
                end
                @test status == 0 && occursin("CLI routed completion 中文",read(output,String))
                @test calls["first"] == 1 && calls["backup"] == 1
                sessions=list_sessions(joinpath(root,"cli-state"))
                @test length(sessions) == 1
                session=load_session(joinpath(root,"cli-state"),sessions[1]["id"])
                @test session.status == :complete && last(session.messages).native["route"]["profile"] == "backup"
                @test session.usage[1].input_tokens == 5 && session.usage[1].output_tokens == 3
                status=open(output,"w") do stream
                    redirect_stdout(stream) do
                        ShenScope.main(["chat","invalid role","--model-role","missing",common...])
                    end
                end
                @test status == 1 && calls["first"] == 1 && calls["backup"] == 1
            end
        end
    end
end
