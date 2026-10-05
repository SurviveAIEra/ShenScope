#!/usr/bin/env julia
# Run under the separate PackageCompiler environment, never Pkg.add into Core.
using PackageCompiler, ShenScope, TOML, SHA, UUIDs

root=realpath(joinpath(@__DIR__,".."))
length(ARGS)==1 || error("Provide one output directory below the application checkout")
output=abspath(ARGS[1])
relative=relpath(output,root)
!isabspath(relative) && first(splitpath(relative))!=".." || error("Build output must remain inside the application checkout")
ispath(output) && islink(output) && error("Build output symlinks are unsupported")
mkpath(output);realpath(output)==output || error("Build output must be a real directory")
image=joinpath(output,"shenscope-core.so");receipt_path=joinpath(output,"shenscope-core.receipt.json")
ispath(image) && error("An image already exists here; retain one reviewed artifact and choose its replacement explicitly")
compiler_project=Base.active_project()
build_manifest=joinpath(dirname(compiler_project),"Manifest.toml")
core_manifest=TOML.parsefile(joinpath(root,"Manifest.toml"))["deps"]
compiler_manifest=TOML.parsefile(build_manifest)["deps"]
for (name,rows) in core_manifest
    candidate=get(compiler_manifest,name,nothing)
    candidate===nothing && error("Build environment omits a Core dependency")
    for key in ("uuid","version","git-tree-sha1")
        get(rows[1],key,nothing)==get(candidate[1],key,nothing) || error("Build environment changed a Core dependency: "*name)
    end
end
ctx=RuntimeContext(root;state_dir=joinpath(output,"state-unused"),permissions=PermissionPolicy(;
    rules=Dict(:read=>Allow,:persistence=>Allow,:dynamic=>Deny,:process=>Deny,:network=>Deny)),
    budget=BudgetLedger(BudgetLimits(;max_seconds=3600)))
snapshot=runtime_source_snapshot(ctx;root)
started=time()
PackageCompiler.create_sysimage([:ShenScope];project=root,sysimage_path=image,incremental=true,
    cpu_target="generic",precompile_execution_file=joinpath(root,"scripts/precompile_sysimage.jl"),
    sysimage_build_args=`--startup-file=no --threads=1 --gcthreads=1 -O2`)
receipt=runtime_image_receipt(snapshot,image,ctx;build_environment_sha256=bytes2hex(sha256(read(build_manifest))),
    compiler_uuid=Base.PkgId(PackageCompiler).uuid,compiler_version=Base.pkgversion(PackageCompiler))
published=runtime_image_write_receipt(receipt_path,receipt,ctx)
verified=runtime_image_verify(receipt_path,ctx;source_root=root)
println(canonical(Dict("scope"=>"single generic Linux sysimage experiment; existing Core checkout and shared depot",
    "elapsed_seconds"=>time()-started,"image_bytes"=>receipt.image_bytes,"image_sha256"=>receipt.image_sha256,
    "source_fingerprint"=>verified.source_fingerprint,"receipt"=>published,"standalone_app_built"=>false)))
