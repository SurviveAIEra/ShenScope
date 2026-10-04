function await_model_job(server,id;timeout=25)
    manager = ShenScope.server_models_tool(server).manager.operations
    @test timedwait(()->manager.jobs[id].status != :running,timeout;pollint=0.01) == :ok
    job = manager.jobs[id];wait(job.task);job
end

function approve_model_rpc(server,owner;decision="once")
    @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
    request = first(keys(server.approvals))
    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>decision))
end

@testset "Model RPC owns operations, approvals, caches and configuration lifecycle" begin
    mktempdir() do root
        calls = Ref(0);captured = String[]
        model_service_fixture(request->begin
            calls[] += 1;push!(captured,HTTP.header(request,"Authorization",""))
            HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict("data"=>[Dict("id"=>"second"),Dict("id"=>"first")])) )
        end) do endpoint
            config = joinpath(root,"config.toml")
            write(config,"[provider]\nendpoint='"*endpoint*"'\nmodel='active'\nkey_env='SHENSCOPE_RPC_FIXTURE'\n[permissions]\nread='ask'\nnetwork='ask'\n")
            server = CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
            try
                hello = dispatch_rpc(server,"initialize",Dict())
                @test hello["capabilities"]["model_catalog"] && hello["capabilities"]["model_counting"]
                owner = dispatch_rpc(server,"sessions/create",Dict())["id"]
                foreign = dispatch_rpc(server,"sessions/create",Dict())["id"]
                @test_throws ShenScopeError dispatch_rpc(server,"models/query",Dict("session_id"=>owner))
                @test_throws RPCFault dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"unexpected"=>true))
                @test_throws RPCFault dispatch_rpc(server,"models/unknown",Dict("session_id"=>owner))
                status = dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"status"))
                approve_model_rpc(server,owner;decision="session")
                @test await_model_job(server,status["job_id"]).result["catalog_lifetime"] == "conversation"
                dispatch_rpc(server,"credentials/set",Dict("variable"=>"SHENSCOPE_RPC_FIXTURE","value"=>"rpc-fixture-private"))
                started = dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"refresh"))
                @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
                @test_throws ShenScopeError dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"status"))
                configuration = dispatch_rpc(server,"config/get",Dict())
                @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>configuration["value"],"expected_sha256"=>configuration["sha256"]))
                for method in ("models/job","models/cancel_job")
                    @test_throws ShenScopeError dispatch_rpc(server,method,Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
                    @test_throws RPCFault dispatch_rpc(server,method,Dict("session_id"=>owner,"job_id"=>started["job_id"],"unexpected"=>true))
                end
                request = first(keys(server.approvals))
                @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>foreign,"request_id"=>request,"decision"=>"once"))
                dispatch_rpc(server,"models/cancel_job",Dict("session_id"=>owner,"job_id"=>started["job_id"]))
                @test await_model_job(server,started["job_id"]).status == :cancelled
                @test calls[] == 0 && isempty(server.approvals)
                @test !iscancelled(server.contexts[owner].cancellation)
                refresh = dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"refresh","offset"=>1,"limit"=>1))
                approve_model_rpc(server,owner)
                completed = await_model_job(server,refresh["job_id"])
                @test completed.status == :complete && completed.result["models"][1]["id"] == "second"
                @test calls[] == 1 && only(captured) == "Bearer rpc-fixture-private"
                view = dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"limit"=>1))
                @test view["catalog"]["total"] == 2 && view["catalog"]["next_offset"] == 1
                @test view["status"]["configured"]["id"] == "active"
                @test !occursin("rpc-fixture-private",canonical(view))
                @test isempty(dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"offset"=>typemax(Int)))["catalog"]["models"])
                @test_throws ShenScopeError dispatch_rpc(server,"models/query",Dict("session_id"=>owner,"offset"=>true))
                server.contexts[foreign] = RuntimeContext(root;session_id=foreign,state_dir=server.state_dir,permissions=PermissionPolicy())
                @test dispatch_rpc(server,"models/query",Dict("session_id"=>foreign))["catalog"]["total"] == 0
                count = dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"count","mode"=>"estimate",
                    "request"=>Dict("messages"=>[Dict("role"=>"user","text"=>"中文😀")],"max_output"=>32)))
                @test await_model_job(server,count["job_id"]).result["source"] == "estimate"
                @test calls[] == 1
                pending = dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"refresh","force"=>true))
                @test timedwait(()->!isempty(server.approvals),10;pollint=0.01) == :ok
                dispatch_rpc(server,"credentials/set",Dict("variable"=>"SHENSCOPE_RPC_FIXTURE","value"=>"rotated-fixture"))
                @test await_model_job(server,pending["job_id"]).status == :cancelled
                @test isempty(server.approvals) && calls[] == 1
                @test dispatch_rpc(server,"models/query",Dict("session_id"=>owner))["catalog"]["total"] == 0
                manager = ShenScope.server_models_tool(server).manager
                @test haskey(dispatch_rpc(server,"config/set",Dict("value"=>configuration["value"],"expected_sha256"=>configuration["sha256"])),"sha256")
                @test manager.closed && isempty(manager.operations.jobs)
                @test_throws ShenScopeError dispatch_rpc(server,"models/start",Dict("session_id"=>owner,"action"=>"status","unexpected"=>true))
            finally
                stop_server!(server)
            end
        end
    end
end
