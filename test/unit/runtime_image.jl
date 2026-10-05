@testset "Runtime image receipts pin source inventory and refuse changed source, lock and artifact" begin
    mktempdir() do root
        fixture=runtime_image_fixture(root);ctx=fixture.context
        receipt=runtime_fixture_receipt(fixture)
        @test length(receipt.source.files)==4
        @test runtime_image_write_receipt(fixture.receipt,receipt,ctx)["bytes"]>0
        inspected=runtime_image_inspect(fixture.receipt,ctx)
        @test !inspected["verified_image_bytes"] && !inspected["signature_verified"]
        verified=runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        @test verified.source_fingerprint==receipt.source.fingerprint
        plan=runtime_image_launch_arguments(verified,ctx)
        @test "--sysimage="*fixture.image in plan["arguments"] && !plan["process_started"]
        @test !plan["compiled_instructions_attested"]
        write(joinpath(fixture.source,"src","中文.jl"),"value=\"changed\"\n")
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        @test_throws ShenScopeError runtime_image_launch_arguments(verified,ctx)
        write(joinpath(fixture.source,"src","中文.jl"),"value=\"🙂\"\n")
        write(joinpath(fixture.source,"src","added.jl"),"added=true\n")
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        rm(joinpath(fixture.source,"src","added.jl"))
        write(joinpath(fixture.source,"Manifest.toml"),"changed=true\n")
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        write(joinpath(fixture.source,"Manifest.toml"),"julia_version=\"1.11.7\"\nmanifest_format=\"2.0\"\n")
        write(joinpath(fixture.source,"LocalPreferences.toml"),"[PrecompileTools]\nprecompile_workload=false\n")
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        rm(joinpath(fixture.source,"LocalPreferences.toml"))
        bytes=read(fixture.image);bytes[end]=0x01;write(fixture.image,bytes)
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
    end
end

@testset "Runtime receipts enforce schema, platform, symlinks and independent permissions" begin
    mktempdir() do root
        fixture=runtime_image_fixture(root);ctx=fixture.context;receipt=runtime_fixture_receipt(fixture)
        value=runtime_image_view(receipt)
        wrong=deepcopy(value);wrong["runtime"]["julia_version"]="99.0.0";write(fixture.receipt,canonical(wrong))
        @test_throws ShenScopeError runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        wrong=deepcopy(value);wrong["image"]["name"]="../escape.so"
        @test_throws ShenScopeError ShenScope.runtime_image_from_view(wrong)
        wrong=deepcopy(value);wrong["source"]["files"][1]["path"]="../escape.jl"
        @test_throws ShenScopeError ShenScope.runtime_image_from_view(wrong)
        wrong=deepcopy(value);wrong["source"]["files"][1]["bytes"]=true
        @test_throws ShenScopeError ShenScope.runtime_image_from_view(wrong)
        wrong=deepcopy(value);wrong["source"]["fingerprint"]=digest("wrong")
        @test_throws ShenScopeError ShenScope.runtime_image_from_view(wrong)
        wrong=deepcopy(value);wrong["extra"]=true
        @test_throws ShenScopeError ShenScope.runtime_image_from_view(wrong)
        @test_throws ShenScopeError RuntimeSourceFile("x/../y",1,digest("x"))
        write(fixture.receipt,"{\"schema\":\"a\",\"schema\":\"b\"}")
        @test_throws ShenScopeError runtime_image_inspect(fixture.receipt,ctx)
        write(fixture.receipt,"{\"nested\":"*repeat("[",40)*"0"*repeat("]",40)*"}")
        @test_throws ShenScopeError runtime_image_inspect(fixture.receipt,ctx)
        runtime_image_write_receipt(fixture.receipt,receipt,ctx)
        verified=runtime_image_verify(fixture.receipt,ctx;source_root=fixture.source)
        ctx.permissions.rules[:dynamic]=Deny
        @test_throws ShenScopeError runtime_image_launch_arguments(verified,ctx)
        ctx.permissions.rules[:persistence]=Deny
        @test_throws ShenScopeError runtime_image_write_receipt(fixture.receipt,receipt,ctx)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError runtime_image_inspect(fixture.receipt,ctx)
        ctx.permissions.rules[:read]=Allow
        symlink(fixture.image,joinpath(root,"linked.so"))
        @test_throws ShenScopeError ShenScope.runtime_image_hash(joinpath(root,"linked.so"),ctx)
        symlink(joinpath(fixture.source,"src","ShenScope.jl"),joinpath(fixture.source,"src","linked.jl"))
        @test_throws ShenScopeError runtime_source_snapshot(ctx;root=fixture.source)
        prior=get(ENV,"SHENSCOPE_IMAGE_SOURCE_DIGEST",nothing)
        try
            ENV["SHENSCOPE_IMAGE_SOURCE_DIGEST"]="not-a-hash"
            @test ShenScope.runtime_loaded_image_view()["loader_reported_source_fingerprint"]===nothing
        finally
            prior===nothing ? delete!(ENV,"SHENSCOPE_IMAGE_SOURCE_DIGEST") : (ENV["SHENSCOPE_IMAGE_SOURCE_DIGEST"]=prior)
        end
    end
end
