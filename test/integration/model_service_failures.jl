@testset "Model services bound declared/chunked bodies and reject redirects" begin
    mktempdir() do root
        for mode in (:declared,:chunked,:redirect)
            model_service_fixture(stream->begin
                try
                    if mode == :redirect
                        HTTP.setstatus(stream,302);HTTP.setheader(stream,"Location"=>"http://127.0.0.1:1/unapproved")
                    else
                        HTTP.setstatus(stream,200);HTTP.setheader(stream,"Content-Type"=>"application/json")
                        mode == :declared && HTTP.setheader(stream,"Content-Length"=>"4096")
                        mode == :chunked && HTTP.setheader(stream,"Transfer-Encoding"=>"chunked")
                    end
                    HTTP.startwrite(stream)
                    mode == :redirect || write(stream,canonical(Dict("data"=>Any[],"padding"=>repeat("x",2048))))
                catch
                    # The bounded client intentionally closes oversized bodies.
                end
            end;stream=true) do endpoint
                provider = HTTPProvider(ProviderConfig(;endpoint,retries=0,timeout=15.0))
                request = ShenScope.model_service_request(provider,ShenScope.CredentialSnapshot("fixture"),"catalog")
                error = try ShenScope.model_service_json(provider,request,model_context(root);max_bytes=1024);nothing catch cause;cause end
                @test error isa ShenScopeError
                @test error.code == (mode == :redirect ? :request : :capacity)
                @test !occursin("padding",error.message) && !occursin("unapproved",error.message)
            end
        end
    end
end

@testset "Model service blocked reads retire on cancellation, revocation and deadline" begin
    for mode in (:cancel,:revoke,:timeout,:budget)
        mktempdir() do root
            ready = Channel{Bool}(1);release = Channel{Bool}(1)
            model_service_fixture(stream->begin
                try
                    HTTP.setstatus(stream,200);HTTP.setheader(stream,"Content-Type"=>"application/json")
                    HTTP.setheader(stream,"Transfer-Encoding"=>"chunked");HTTP.startwrite(stream)
                    write(stream,"{\"data\":");put!(ready,true);take!(release);write(stream,"[]}")
                catch
                end
            end;stream=true) do endpoint
                owner = model_context(root);ctx = child_context(owner)
                mode == :budget && (ctx.budget = BudgetLedger(BudgetLimits(;max_seconds=0.3)))
                provider = HTTPProvider(ProviderConfig(;endpoint,retries=0,timeout=mode == :timeout ? 0.3 : 10.0))
                request = ShenScope.model_service_request(provider,ShenScope.CredentialSnapshot(""),"catalog")
                worker = @async try ShenScope.model_service_json(provider,request,ctx);nothing catch cause;cause end
                try
                    if mode in (:cancel,:revoke)
                        @test timedwait(()->isready(ready),10;pollint=0.01) == :ok
                        mode == :cancel ? cancel!(ctx.cancellation,"Cancel held response") : (ctx.permissions.rules[:network] = Deny)
                    end
                    @test timedwait(()->istaskdone(worker),5;pollint=0.01) == :ok
                    failure = fetch(worker)
                    @test failure isa ShenScopeError
                    @test failure.code == (mode == :cancel ? :cancelled : mode == :revoke ? :permission : mode == :timeout ? :timeout : :budget)
                    @test !iscancelled(owner.cancellation)
                finally
                    put!(release,true)
                end
            end
        end
    end
end

@testset "Single refresh approval covers pages and scope checks prevent reusing it elsewhere" begin
    mktempdir() do root
        calls = Ref(0);approved = Symbol[]
        model_service_fixture(request->begin
            calls[] += 1
            HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict("data"=>[Dict("id"=>"id-"*string(calls[]))],
                "has_more"=>calls[] == 1,"last_id"=>"next")))
        end) do endpoint
            provider = HTTPProvider(ProviderConfig(;endpoint,retries=0))
            ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Ask,:network=>Ask)),
                approve=request->(push!(approved,request.category);:once))
            manager = ModelCatalogManager()
            @test refresh_model_catalog!(manager,provider,ctx)["total"] == 2
            @test count(==(:read),approved) == 1 && count(==(:network),approved) == 1
            request = ShenScope.model_service_request(provider,ShenScope.CredentialSnapshot(""),"catalog")
            grant = ShenScope.authorize_model_service!(provider,request,ctx)
            foreign = child_context(ctx;session_id="foreign")
            @test_throws ShenScopeError ShenScope.model_service_json(provider,request,foreign;authorization=grant)
            @test_throws ShenScopeError ShenScope.model_service_json(provider,request,child_context(ctx);authorization=grant)
            ShenScope.cleanup_model_catalogs!(manager)
        end
    end
end

@testset "Catalog capacity failure preserves the prior snapshot and scoped cleanup preserves siblings" begin
    mktempdir() do root
        large = Ref(false)
        model_service_fixture(request->HTTP.Response(200,["Content-Type"=>"application/json"],canonical(Dict("data"=>
            [Dict("id"=>"active","name"=>large[] ? repeat("x",900) : "short")]))) ) do endpoint
            provider = HTTPProvider(ProviderConfig(;endpoint,retries=0));ctx = model_context(root)
            manager = ModelCatalogManager(;max_sources=2,max_bytes=1024)
            first = refresh_model_catalog!(manager,provider,ctx)
            large[] = true
            @test_throws ShenScopeError refresh_model_catalog!(manager,provider,ctx;force=true)
            @test model_catalog_view(manager,provider,ctx)["revision"] == first["revision"]
            large[] = false
            sibling = child_context(ctx;session_id="sibling")
            @test refresh_model_catalog!(manager,provider,sibling)["total"] == 1
            foreign = child_context(ctx;session_id="capacity")
            @test_throws ShenScopeError refresh_model_catalog!(manager,provider,foreign)
            ShenScope.release_model_catalog_session!(manager,ctx.session_id)
            @test model_catalog_view(manager,provider,ctx)["total"] == 0
            @test model_catalog_view(manager,provider,sibling)["total"] == 1
            @test refresh_model_catalog!(manager,provider,foreign)["total"] == 1
            view = model_catalog_view(manager,provider,sibling);view["models"][1]["features"]["tools"] = true
            @test model_catalog_view(manager,provider,sibling)["models"][1]["features"]["tools"] === nothing
            ShenScope.cleanup_model_catalogs!(manager)
        end
    end
end
