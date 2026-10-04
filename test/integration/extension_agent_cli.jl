@testset "Registered tools enter a real agent request with generation-fenced execution" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root);ctx.permissions.rules[:persistence]=Allow
        control=ExtensionsTool()
        register_extension!(control.registry,ExtensionLifecycleFixtures.bundle(),ctx)
        activate_extension!(control.registry,"counter_extension",ctx)
        wrapper=only(active_extension_tools(control.registry,ctx))
        provider=MockProvider([response(;calls=[ToolCall(ShenScope.tool_name(wrapper),Dict("value"=>9))]),response("Extension ran.")])
        session=new_session(ctx)
        @test run_agent!(provider,"Call the registered extension",ctx;session,tools=[control])=="Extension ran."
        result=parsejson(only(message.text for message in session.messages if message.role==:tool))
        @test result["ok"] && result["value"]["count"]==1
        @test any(spec->spec["name"]==ShenScope.tool_name(wrapper),provider.requests[1].tools)
        @test session.status==:complete
        @test close_extension_registry!(control.registry)["cleanup_failures"]==0
    end
end

@testset "CLI invokes a pinned independent package and closes its ephemeral registry" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root)
        fixture=realpath(joinpath(@__DIR__,"..","fixtures","extensions","ShenScopeLifecycleExample"))
        old_path=copy(LOAD_PATH)
        try
            push!(LOAD_PATH,fixture)
            receipt=installed_extension_receipt("ShenScopeLifecycleExample",ExtensionLifecycleFixtures.UUID_VALUE,ctx)
            config=joinpath(root,"config.toml")
            write(config,"[permissions]\nread='allow'\ndynamic='allow'\nprocess='allow'\npersistence='allow'\nnetwork='deny'\n")
            args=["extensions","invoke","installed_example","--root",root,"--config",config,"--state-dir",ctx.state_dir,
                "--package-name",receipt["name"],"--package-uuid",receipt["uuid"],"--package-version",receipt["version"],
                "--entry-sha256",receipt["entry_sha256"],"--project-sha256",receipt["project_sha256"],
                "--contribution","echo","--arguments","{\"text\":\"CLI extension\"}"]
            @test ShenScope.main(args)==0
            @test_throws ShenScopeError ShenScope.cli_extensions_command(["extensions","activate","installed_example"],
                Dict("--root"=>root),ShenScope.load_config(;path=config),ctx.state_dir)
        finally
            empty!(LOAD_PATH);append!(LOAD_PATH,old_path)
        end
    end
end
