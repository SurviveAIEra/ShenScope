@testset "Extension factories are permissioned and publish complete generations" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);registry=ExtensionRegistry()
        calls=Ref(0);closed=Ref(0);bundle=ExtensionLifecycleFixtures.bundle(;calls,closed)
        @test register_extension!(registry,bundle,ctx)["phase"]=="inactive"
        empty!(bundle.contributions)
        @test length(extension_inspect(registry,"counter_extension",ctx)["contributions"])==1
        @test extension_error_code(()->register_extension!(registry,ExtensionLifecycleFixtures.bundle(),ctx))==:conflict
        view=activate_extension!(registry,"counter_extension",ctx)
        @test view["phase"]=="active" && view["contributions"][1]["contract"]["valid"]
        wrappers=active_extension_tools(registry,ctx);tool=only(wrappers)
        @test startswith(ShenScope.tool_name(tool),"ext_") && ncodeunits(ShenScope.tool_name(tool))<=64
        @test execute(tool,Dict("value"=>3),ctx)==Dict("count"=>1,"value"=>3)
        @test extension_error_code(()->execute(tool,Dict("value"=>-1),ctx))==:arguments
        @test calls[]==1
        @test deactivate_extension!(registry,"counter_extension",ctx)["phase"]=="inactive"
        @test closed[]==1
        @test extension_error_code(()->execute(tool,Dict("value"=>3),ctx))==:extension_busy
        next=activate_extension!(registry,"counter_extension",ctx)
        @test next["generation"]>view["generation"]
        @test extension_error_code(()->execute(tool,Dict("value"=>3),ctx))==:conflict
        deactivate_extension!(registry,"counter_extension",ctx)
        @test unregister_extension!(registry,"counter_extension",ctx)["removed"]
        register_extension!(registry,ExtensionLifecycleFixtures.bundle(),ctx)
        activate_extension!(registry,"counter_extension",ctx)
        @test extension_error_code(()->execute(tool,Dict("value"=>3),ctx))==:conflict
        deactivate_extension!(registry,"counter_extension",ctx)
    end
end

@testset "Extension control tools expose reviewed schemas and agent snapshots" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);closed=Ref(0);tool=ExtensionsTool()
        register_extension!(tool.registry,ExtensionLifecycleFixtures.bundle(;closed),ctx)
        view=execute(tool,Dict("action"=>"activate","name"=>"counter_extension"),ctx)
        schema=execute(tool,Dict("action"=>"inspect_tool","name"=>"counter_extension","contribution"=>"counter"),ctx)
        @test schema["generation"]==view["generation"] && schema["schema"]["required"]==["value"]
        args=Dict("action"=>"invoke","name"=>"counter_extension","contribution"=>"counter",
            "generation"=>view["generation"],"registry_id"=>view["registry_id"],"arguments"=>Dict("value"=>5))
        @test execute(tool,args,ctx)["value"]["count"]==1
        @test extension_error_code(()->execute(tool,merge(args,Dict("registry_id"=>string(Base.UUID(0)))),ctx))==:conflict
        @test length(extension_tool_snapshot([tool],ctx))==2
        schema["schema"]["properties"]["value"]["maximum"]=99
        @test execute(tool,Dict("action"=>"inspect_tool","name"=>"counter_extension","contribution"=>"counter"),ctx)["schema"]["properties"]["value"]["maximum"]==100
        @test close_extension_registry!(tool.registry)["cleanup_failures"]==0
        @test closed[]==1
        @test extension_error_code(()->extension_list(tool.registry,ctx))==:extension_closed
    end
end

@testset "Extension draining fences calls and preserves leased instances" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);registry=ExtensionRegistry();closed=Ref(0)
        register_extension!(registry,ExtensionLifecycleFixtures.bundle(;closed),ctx)
        activate_extension!(registry,"counter_extension",ctx)
        started=Channel{Nothing}(1);release=Channel{Nothing}(1)
        running=@async with_extension_instance(registry,"counter_extension","counter",ctx) do tool
            put!(started,nothing);take!(release);:finished
        end
        take!(started)
        view=deactivate_extension!(registry,"counter_extension",ctx;timeout=0)
        @test view["phase"]=="draining" && view["active_calls"]==1
        @test closed[]==0
        @test extension_error_code(()->ShenScope.acquire_extension_lease!(registry,"counter_extension","counter",ctx))==:extension_busy
        @test extension_error_code(()->unregister_extension!(registry,"counter_extension",ctx))==:extension_busy
        put!(release,nothing);@test fetch(running)==:finished
        @test extension_inspect(registry,"counter_extension",ctx)["active_calls"]==0
        @test deactivate_extension!(registry,"counter_extension",ctx)["phase"]=="inactive"
        @test closed[]==1
    end
end

@testset "Failed factories quarantine resources and cleanup failures stay visible" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);registry=ExtensionRegistry();closed=Ref(0)
        register_extension!(registry,ExtensionLifecycleFixtures.bundle(;closed,fail=true),ctx)
        @test extension_error_code(()->activate_extension!(registry,"counter_extension",ctx))==:extension_factory
        @test closed[]==1
        view=extension_inspect(registry,"counter_extension",ctx)
        @test view["phase"]=="quarantined" && view["failure_stage"]=="factory"
        @test all(item->!item["active"],view["contributions"])
        @test extension_error_code(()->activate_extension!(registry,"counter_extension",ctx))==:extension_busy
        unregister_extension!(registry,"counter_extension",ctx)
        register_extension!(registry,ExtensionLifecycleFixtures.bundle(;cleanup_fail=true),ctx)
        activate_extension!(registry,"counter_extension",ctx)
        @test deactivate_extension!(registry,"counter_extension",ctx)["cleanup_failures"]==1
        @test extension_error_code(()->unregister_extension!(registry,"counter_extension",ctx))==:extension_cleanup
        @test unregister_extension!(registry,"counter_extension",ctx;accept_cleanup_failure=true)["cleanup_failures"]==1
        bad=ExtensionBundle("missing",ExtensionLifecycleFixtures.UUID_VALUE,v"0.1.0",
            [ExtensionContribution("missing",:tool,ctx->ExtensionLifecycleFixtures.MissingTool())])
        register_extension!(registry,bad,ctx)
        @test extension_error_code(()->activate_extension!(registry,"missing",ctx))==:extension_contract
    end
end

@testset "Extension schemas, root ownership and live dynamic denial are enforced" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);registry=ExtensionRegistry();calls=Ref(0)
        denied=ExtensionLifecycleFixtures.context(root;dynamic=Deny)
        @test extension_error_code(()->register_extension!(registry,ExtensionLifecycleFixtures.bundle(),denied))==:permission
        @test isempty(extension_list(registry,ctx)["extensions"])
        register_extension!(registry,ExtensionLifecycleFixtures.bundle(;calls),ctx)
        @test extension_error_code(()->activate_extension!(registry,"counter_extension",denied))==:permission
        activate_extension!(registry,"counter_extension",ctx)
        tool=only(active_extension_tools(registry,ctx))
        @test extension_error_code(()->execute(tool,Dict("value"=>1),denied))==:permission
        @test calls[]==0
        with_extension_instance(registry,"counter_extension","counter",ctx) do instance
            instance.schema["properties"]["value"]["maximum"]=200
        end
        @test extension_error_code(()->execute(tool,Dict("value"=>1),ctx))==:conflict
        @test calls[]==0
        mktempdir() do foreign
            @test extension_error_code(()->extension_list(registry,ExtensionLifecycleFixtures.context(foreign)))==:permission
        end
        @test_throws ShenScopeError ExtensionContribution("../bad",:tool,ctx->nothing)
        @test_throws ShenScopeError ExtensionBundle("invalid",ExtensionLifecycleFixtures.UUID_VALUE,v"0.1.0",ExtensionContribution[])
        incompatible=ExtensionBundle("future",ExtensionLifecycleFixtures.UUID_VALUE,v"0.1.0",
            [ExtensionContribution("counter",:tool,ctx->nothing)];minimum_core=v"99.0.0",maximum_core=v"100.0.0")
        @test extension_error_code(()->register_extension!(registry,incompatible,ctx))==:extension_compatibility
        deactivate_extension!(registry,"counter_extension",ctx)
    end
end
