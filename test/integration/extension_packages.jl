@testset "Installed Julia package loading pins identity, source and real dispatch" begin
    mktempdir() do root
        ctx=ExtensionLifecycleFixtures.context(root)
        fixture=joinpath(@__DIR__,"..","fixtures","extensions","ShenScopeLifecycleExample")
        old_path=copy(LOAD_PATH)
        try
            push!(LOAD_PATH,realpath(fixture))
            name="ShenScopeLifecycleExample";uuid=ExtensionLifecycleFixtures.UUID_VALUE
            receipt=installed_extension_receipt(name,uuid,ctx)
            @test receipt["name"]==name && receipt["version"]=="0.1.0"
            @test !receipt["dependencies_verified"] && !receipt["all_package_sources_verified"]
            registry=ExtensionRegistry()
            wrong=InstalledExtensionSpec(name,uuid,v"0.1.0",repeat("0",64),receipt["project_sha256"])
            @test extension_error_code(()->load_installed_extension!(registry,wrong,ctx))==:conflict
            spec=InstalledExtensionSpec(name,uuid,v"0.1.0",receipt["entry_sha256"],receipt["project_sha256"])
            denied=ExtensionLifecycleFixtures.context(root;dynamic=Deny)
            @test extension_error_code(()->load_installed_extension!(registry,spec,denied))==:permission
            @test isempty(extension_list(registry,ctx)["extensions"])
            if Base.JLOptions().use_compiled_modules==1
                @test extension_error_code(()->load_installed_extension!(registry,spec,ctx))==:permission
                ctx.permissions.rules[:process]=Allow;ctx.permissions.rules[:persistence]=Allow
            end
            @test load_installed_extension!(registry,spec,ctx)["phase"]=="inactive"
            @test installed_extension_receipt(name,uuid,ctx)["module_already_loaded"]
            @test activate_extension!(registry,"installed_example",ctx)["phase"]=="active"
            tool=only(active_extension_tools(registry,ctx))
            @test execute(tool,Dict("text"=>"独立 Julia 扩展"),ctx)["echo"]=="独立 Julia 扩展"
            @test deactivate_extension!(registry,"installed_example",ctx)["phase"]=="inactive"
            @test unregister_extension!(registry,"installed_example",ctx)["julia_methods_unloaded"]==false
            @test extension_error_code(()->installed_extension_receipt("MissingShenScopePackage",uuid,ctx))==:extension_package
            @test_throws ShenScopeError InstalledExtensionSpec("../unsafe",uuid,v"0.1.0",repeat("0",64),repeat("0",64))
        finally
            empty!(LOAD_PATH);append!(LOAD_PATH,old_path)
        end
    end
end
