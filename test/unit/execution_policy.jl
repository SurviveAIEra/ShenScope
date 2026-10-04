@testset "Execution policy validates before configuration mutation" begin
    @test ShenScope.sandbox_from_config(Dict()) isa ShenScope.HostSandbox
    isolated=ShenScope.sandbox_from_config(Dict("sandbox"=>Dict("backend"=>"bubblewrap")))
    @test isolated isa ShenScope.BubblewrapSandbox
    @test isolated.policy.filesystem==:read_only && isolated.policy.network==:closed
    for value in (true,[],"bubblewrap",Dict("backend"=>"other"),Dict("backend"=>"host","network"=>"closed"),
            Dict("backend"=>"bubblewrap","filesystem"=>true),Dict("backend"=>"bubblewrap","network"=>"allow"),
            Dict("backend"=>"bubblewrap","runtime_roots"=>["/"]),Dict("backend"=>"bubblewrap","runtime_roots"=>["relative"]),
            Dict("backend"=>"bubblewrap","runtime_roots"=>["/usr/../etc"]),Dict("backend"=>"bubblewrap","environment_keys"=>["LD_PRELOAD"]),
            Dict("backend"=>"bubblewrap","limits"=>Dict("cpu_seconds"=>true)),Dict("backend"=>"bubblewrap","limits"=>Dict("open_files"=>3)))
        @test_throws ShenScopeError ShenScope.sandbox_from_config(Dict("sandbox"=>value))
    end
    for limits in (Dict(:cpu_seconds=>0),Dict(:file_bytes=>0),Dict(:open_files=>5000),Dict(:address_space_bytes=>1))
        @test_throws ShenScopeError ShenScope.ExecutionLimits(;limits...)
    end
    mktempdir() do root
        path=joinpath(root,"config.toml");write(path,"# ORIGINAL CONFIG\n")
        config=load_config(;path);config["sandbox"]=Dict("backend"=>"host","network"=>"closed")
        called=Ref(false)
        @test_throws ShenScopeError save_config!(config;path,before_write=()->(called[]=true))
        @test !called[] && read(path,String)=="# ORIGINAL CONFIG\n"
    end
end

@testset "Restricted environment excludes credentials and values from evidence" begin
    policy=ShenScope.ExecutionPolicy()
    values=ShenScope.execution_environment(policy;source=Dict("MODEL_KEY"=>"fixture-secret","LD_PRELOAD"=>"fixture-injection","LANG"=>"C.UTF-8"))
    env=Dict(values)
    @test !haskey(env,"MODEL_KEY") && !haskey(env,"LD_PRELOAD")
    @test env["LANG"]=="C.UTF-8" && env["HOME"]=="/tmp/shenscope-home"
    @test env["PATH"]=="/usr/local/bin:/usr/bin:/bin"
    @test !occursin("C.UTF-8",canonical(ShenScope.execution_environment_view(values)))
    @test_throws ShenScopeError ShenScope.execution_environment(policy;overlay=Dict("MODEL_KEY"=>"fixture-secret"))
    @test_throws ShenScopeError ShenScope.execution_environment(policy;source=Dict("LANG"=>"bad\0value"))
    @test_throws ShenScopeError ShenScope.execution_environment(policy;source=Dict("LANG"=>repeat("x",4097)))
    @test Dict(ShenScope.execution_environment(policy;source=Dict(),overlay=Dict("LANG"=>"fixture-locale")))["LANG"]=="fixture-locale"
end

@testset "Execution plan masks secrets and retains read-only Git metadata" begin
    if Sys.islinux()
        root,ctx=execution_fixture()
        try
            mkpath(joinpath(root,"nested",".git"));mkpath(joinpath(root,".ssh"))
            write(joinpath(root,".env"),"fixture secret");write(joinpath(root,"nested",".env.local"),"fixture secret")
            policy=ShenScope.ExecutionPolicy();sandbox=ShenScope.BubblewrapSandbox(policy)
            plan=ShenScope.execution_plan(sandbox,["/usr/bin/printf","space \$ literal"],ctx)
            kinds=Dict(mask.path=>mask.kind for mask in plan.masks)
            @test kinds[joinpath(root,".env")]==:file
            @test kinds[joinpath(root,".ssh")]==:directory
            @test kinds[joinpath(root,"nested",".git")]==:read_only
            @test kinds[ctx.state_dir]==:directory
            @test count(mount->mount.writable,plan.mounts)==0
            @test plan.argv==( "/usr/bin/printf","space \$ literal")
            @test length(plan.policy_sha256)==64 && plan.nonce!=plan.policy_sha256
            command=collect(plan.command)
            @test "--unshare-all" in command && "--cap-drop" in command && "--clearenv" in command
            @test !("--share-net" in command)
            @test command[end-1:end]==collect(plan.argv)
            private_tmp=findfirst(i->command[i]=="--tmpfs" && command[i+1]=="/tmp",1:length(command)-1)
            bind_root=findfirst(i->command[i] in ("--bind","--ro-bind") && command[i+1]==root && command[i+2]==root,1:length(command)-2)
            @test private_tmp!==nothing && bind_root>private_tmp
            @test ShenScope.execution_validate_mounts(plan,ctx)===nothing
            @test_throws ShenScopeError ShenScope.execution_plan(sandbox,["true"],ctx;cwd=ctx.state_dir)
            @test_throws ShenScopeError ShenScope.execution_plan(sandbox,["true"],ctx;scan_limit=1)
            bad=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy(;runtime_roots=[dirname(root)]))
            @test_throws ShenScopeError ShenScope.execution_plan(bad,["true"],ctx)
            rm(joinpath(root,".env"));symlink(joinpath(root,"nested",".env.local"),joinpath(root,".env"))
            @test_throws ShenScopeError ShenScope.execution_validate_mounts(plan,ctx)
            @test_throws ShenScopeError ShenScope.execution_plan(sandbox,["true"],ctx)
        finally
            rm(root;recursive=true)
        end
    end
end

@testset "Execution evidence confirms setup without claiming payload exec" begin
    root,ctx=execution_fixture()
    try
        if Sys.islinux()
            plan=ShenScope.execution_plan(ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy()),["true"],ctx)
            evidence=ShenScope.ExecutionEvidence(plan);marker=ShenScope.execution_marker(evidence)
            @test isempty(ShenScope.execution_stderr!(evidence,Vector{UInt8}(codeunits(marker[1:19]))))
            @test String(ShenScope.execution_stderr!(evidence,Vector{UInt8}(codeunits(marker[20:end]*"fixture stderr"))))=="fixture stderr"
            view=ShenScope.execution_evidence_view(evidence)
            @test view["os_isolation"] && view["isolation_setup_confirmed"]
            @test !view["payload_exec_verified"] && !view["host_fallback"]
            bad=ShenScope.ExecutionEvidence(plan)
            @test String(ShenScope.execution_stderr!(bad,Vector{UInt8}(codeunits("wrong marker\n"))))=="wrong marker\n"
            @test ShenScope.execution_evidence_view(bad)["phase"]=="unconfirmed"
            partial=ShenScope.ExecutionEvidence(plan)
            ShenScope.execution_stderr!(partial,Vector{UInt8}(codeunits("SHENSCOPE_EXEC")))
            @test String(ShenScope.execution_stderr!(partial,UInt8[];final=true))=="SHENSCOPE_EXEC"
            @test !ShenScope.execution_evidence_view(partial;exited=true)["os_isolation"]
        end
        @test !ShenScope.execution_evidence_view(ShenScope.ExecutionEvidence())["os_isolation"]
        @test !ShenScope.execution_landlock_status()["enforced"]
    finally
        rm(root;recursive=true)
    end
end
