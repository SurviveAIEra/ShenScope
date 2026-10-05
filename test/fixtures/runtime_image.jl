function runtime_image_fixture(root)
    source=joinpath(root,"core-source");mkpath(joinpath(source,"src"));mkpath(joinpath(source,"ext"))
    write(joinpath(source,"Project.toml"),"name=\"ShenScope\"\nuuid=\""*string(Base.PkgId(ShenScope).uuid)*"\"\nversion=\"0.1.0\"\n")
    write(joinpath(source,"Manifest.toml"),"julia_version=\"1.11.7\"\nmanifest_format=\"2.0\"\n")
    write(joinpath(source,"src","ShenScope.jl"),"module ShenScope\nend\n")
    write(joinpath(source,"src","中文.jl"),"value=\"🙂\"\n")
    image=joinpath(root,"core-test.so");bytes=zeros(UInt8,4096)
    bytes[1:6]=UInt8[0x7f,0x45,0x4c,0x46,0x02,0x01];bytes[19]=Sys.ARCH==:x86_64 ? 62 : 183
    write(image,bytes)
    context=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;
        rules=Dict(:read=>Allow,:persistence=>Allow,:dynamic=>Allow,:process=>Deny,:network=>Deny)))
    (source=source,image=image,context=context,receipt=joinpath(root,"core-test.receipt.json"))
end
function runtime_fixture_receipt(fixture)
    snapshot=runtime_source_snapshot(fixture.context;root=fixture.source)
    runtime_image_receipt(snapshot,fixture.image,fixture.context;build_environment_sha256=digest("fixture build environment"),
        compiler_uuid=Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"),compiler_version=v"2.4.3")
end
