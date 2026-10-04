@testset "Retry wait cancellation, network revocation and shared deadlines release inference seats" begin
    for mode in (:cancel,:revoke,:budget,:event_sink)
        mktempdir() do root
            calls=Ref(0);ready=Channel{Bool}(1)
            model_service_fixture(request->begin
                calls[]+=1
                HTTP.Response(503,["Retry-After"=>"1"],"unavailable")
            end) do endpoint
                provider=retry_fixture_provider(endpoint;retries=2,maximum_delay=2.0)
                owner=model_context(root);ctx=child_context(owner)
                ctx.sink=event->begin
                    if event.kind == :model_retry
                        put!(ready,true)
                        mode == :cancel && cancel!(ctx.cancellation,"Cancel retry wait")
                        mode == :revoke && (ctx.permissions.rules[:network]=Deny)
                        mode == :budget && (ctx.budget.limits=BudgetLimits(;max_seconds=0.05))
                        mode == :event_sink && error("PRIVATE POLICY SINK FIXTURE")
                    end
                end
                worker=@async try
                    stream_chat(provider,ModelRequest([Message(:user,"Wait")],Dict{String,Any}[],64,Dict()),(kind,payload)->nothing,ctx)
                    nothing
                catch error
                    error
                end
                @test timedwait(()->istaskdone(worker),25;pollint=0.01) == :ok
                failure=fetch(worker)
                @test failure isa ShenScopeError
                @test failure.code == (mode == :cancel ? :cancelled : mode == :revoke ? :permission : mode == :budget ? :budget : :delivery)
                @test calls[] == 1 && isready(ready)
                @test !iscancelled(owner.cancellation)
                entry=only(values(provider.runtime.circuits.entries))
                @test isempty(entry.leases) && entry.state == :closed && entry.failures == 0 && entry.neutral_outcomes == 1
                @test !occursin("PRIVATE POLICY SINK FIXTURE",failure.message)
            end
        end
    end
end

@testset "Revocation and cancellation retire blocked inference reads without retrying" begin
    for mode in (:cancel,:revoke)
        mktempdir() do root
            ready=Channel{Bool}(1);release=Channel{Bool}(1);calls=Ref(0)
            model_service_fixture(stream->begin
                try
                    read(stream);calls[]+=1
                    HTTP.setstatus(stream,200);HTTP.setheader(stream,"Content-Type"=>"text/event-stream")
                    HTTP.setheader(stream,"Transfer-Encoding"=>"chunked");HTTP.startwrite(stream)
                    write(stream,"data: ");flush(stream);put!(ready,true);take!(release)
                    write(stream,"{}\n\n")
                catch
                end
            end;stream=true) do endpoint
                provider=retry_fixture_provider(endpoint;retries=2)
                owner=model_context(root);ctx=child_context(owner)
                worker=@async try stream_chat(provider,ModelRequest([Message(:user,"Held")],Dict{String,Any}[],64,Dict()),
                    (kind,payload)->nothing,ctx);nothing catch error;error end
                try
                    @test timedwait(()->isready(ready),20;pollint=0.01) == :ok
                    mode == :cancel ? cancel!(ctx.cancellation,"Cancel held inference") : (ctx.permissions.rules[:network]=Deny)
                    @test timedwait(()->istaskdone(worker),5;pollint=0.01) == :ok
                    failure=fetch(worker)
                    @test failure isa ShenScopeError && failure.code == (mode == :cancel ? :cancelled : :permission)
                    @test calls[] == 1 && !iscancelled(owner.cancellation)
                    entry=only(values(provider.runtime.circuits.entries))
                    @test isempty(entry.leases) && entry.neutral_outcomes == 1 && entry.failures == 0
                finally
                    put!(release,true)
                end
            end
        end
    end
end

@testset "Server and worker factories share explicit config, credentials and runtime health" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[provider]\nname='runtime-fixture'\nendpoint='http://127.0.0.1:1'\nmodel='explicit'\nkey_env='SHENSCOPE_RUNTIME_FIXTURE'\n[provider.retry_policy]\nmax_retries=4\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict())
            dispatch_rpc(server,"credentials/set",Dict("variable"=>"SHENSCOPE_RUNTIME_FIXTURE","value"=>"runtime-key-fixture"))
            one=server.provider_factory(server);two=server.provider_factory(server)
            @test one.runtime === two.runtime && one.runtime === ShenScope.server_models_tool(server).provider.runtime
            @test one.runtime.retry_policy.max_retries == 4 && one.config.model == "explicit"
            worker=ShenScope.server_task_tool(server).manager.executor.provider_factory(model_context(root))
            @test worker.runtime === one.runtime && worker.config.endpoint == "http://127.0.0.1:1"
            @test worker.credential_lookup(worker.config.key_env) == "runtime-key-fixture"
            ctx=RuntimeContext(root;state_dir=server.state_dir,permissions=PermissionPolicy())
            scope=ShenScope.model_circuit_key(one,ShenScope.CredentialSnapshot("runtime-key-fixture"),ctx)
            lease=ShenScope.acquire_model_circuit!(one.runtime.circuits,scope,one.runtime.circuit_policy)
            ShenScope.settle_model_circuit!(one.runtime.circuits,lease,:failure;code=:server)
            @test model_health_snapshot(two,ctx)["failures"] == 1
            dispatch_rpc(server,"credentials/set",Dict("variable"=>"SHENSCOPE_RUNTIME_FIXTURE","value"=>"rotated-runtime-fixture"))
            @test !model_health_snapshot(two,ctx)["tracked"] && isempty(one.runtime.circuits.entries)
            @test !occursin("runtime-key-fixture",canonical(ShenScope.model_services_status(one)))
            session=dispatch_rpc(server,"sessions/create",Dict())["id"]
            @test dispatch_rpc(server,"models/query",Dict("session_id"=>session))["health"]["revision"] == 0
        finally
            stop_server!(server)
        end
        @test ShenScope.server_models_tool(server).provider.runtime.circuits.closed
        template=HTTPProvider(ProviderConfig(;endpoint="http://127.0.0.1:1"))
        tools=core_tools(;config=ShenScope.DEFAULT_CONFIG)
        bind_models_provider!(tools,template)
        @test only(tool for tool in tools if tool isa ModelsTool).provider.runtime === template.runtime
        task=only(tool for tool in tools if tool isa TaskTool)
        @test task.manager.executor.provider_factory(model_context(root)).runtime === template.runtime
        for tool in tools;tool isa ModelsTool && cleanup_models_tool!(tool);end
    end
end
