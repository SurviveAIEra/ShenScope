@testset "Already loaded Julia code refuses changed inspected package source" begin
    mktempdir() do root
        package=joinpath(root,"ShenScopeSourceGuardFixture");mkpath(joinpath(package,"src"))
        uuid=Base.UUID("3c5d1f29-4c42-453b-8463-03819dfd9c59")
        write(joinpath(package,"Project.toml"),"name=\"ShenScopeSourceGuardFixture\"\nuuid=\"$(uuid)\"\nversion=\"0.1.0\"\n[deps]\nShenScope=\"3c0e50a5-18b4-4d3a-90e1-bcd141d94adb\"\n")
        entry=joinpath(package,"src","ShenScopeSourceGuardFixture.jl")
        write(entry,"""
        module ShenScopeSourceGuardFixture
        using ShenScope
        shenscope_extension_bundle()=ExtensionBundle("source_guard",Base.UUID("$(uuid)"),v"0.1.0",
            [ExtensionContribution("read",:tool,ctx->ReadTool())])
        end
        """)
        old_path=copy(LOAD_PATH);ctx=ExtensionLifecycleFixtures.context(root)
        ctx.permissions.rules[:process]=Allow;ctx.permissions.rules[:persistence]=Allow
        try
            push!(LOAD_PATH,package)
            receipt=installed_extension_receipt("ShenScopeSourceGuardFixture",uuid,ctx)
            spec=InstalledExtensionSpec(receipt["name"],uuid,v"0.1.0",receipt["entry_sha256"],receipt["project_sha256"])
            registry=ExtensionRegistry()
            @test load_installed_extension!(registry,spec,ctx)["phase"]=="inactive"
            @test installed_extension_receipt(receipt["name"],uuid,ctx)["loaded_entry_observed_by_core"]
            unregister_extension!(registry,"source_guard",ctx)
            open(entry,"a") do io;write(io,"\n# Changed after its Julia module was loaded.\n");end
            changed=installed_extension_receipt(receipt["name"],uuid,ctx)
            changed_spec=InstalledExtensionSpec(changed["name"],uuid,v"0.1.0",changed["entry_sha256"],changed["project_sha256"])
            @test extension_error_code(()->load_installed_extension!(registry,changed_spec,ctx))==:stale_extension_module
            @test isempty(extension_list(registry,ctx)["extensions"])
        finally
            empty!(LOAD_PATH);append!(LOAD_PATH,old_path)
        end
    end
end
