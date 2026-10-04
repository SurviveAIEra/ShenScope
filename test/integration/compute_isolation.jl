function compute_test_context(root; sink=e->nothing, permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow)))
    RuntimeContext(root;state_dir=joinpath(root,"state"),permissions,sink)
end

function compute_test_failure(f)
    try
        f()
        nothing
    catch cause
        cause
    end
end

@testset "Actual Julia compute kernel isolation" begin
    if !ShenScope.compute_seccomp_available()
        @test_skip "Verified Linux/libseccomp compute sandbox unavailable"
    else
        mktempdir() do root
            sentinel = joinpath(root,"sentinel.txt"); write(sentinel,"retained")
            child = Ref{Int}(0)
            observed = Dict{String,String}()
            ctx = compute_test_context(root;sink=event->begin
                if event.kind == :isolated_compute_ready
                    child[] = event.payload["pid"]
                    for line in eachline("/proc/$(child[])/status")
                        startswith(line,"NoNewPrivs:") && (observed["nnp"]=strip(split(line,':';limit=2)[2]))
                        startswith(line,"Seccomp:") && (observed["seccomp"]=strip(split(line,':';limit=2)[2]))
                    end
                end
            end)
            source = raw"""
            selftest() = true
            function attempt(f)
                value = f()
                Dict("value"=>value,"errno"=>Base.Libc.errno())
            end
            function analyze(data, request)
                path = data["path"]
                results = Dict{String,Any}()
                results["open_read"] = attempt(() -> ccall(:open,Cint,(Cstring,Cint),path,0))
                results["open_write"] = attempt(() -> ccall(:open,Cint,(Cstring,Cint,Cint),path,0x241,0o600))
                results["socket"] = attempt(() -> ccall(:socket,Cint,(Cint,Cint,Cint),2,1,0))
                pair = zeros(Cint,2)
                results["socketpair"] = attempt(() -> ccall(:socketpair,Cint,(Cint,Cint,Cint,Ptr{Cint}),1,1,0,pair))
                results["unlink"] = attempt(() -> ccall(:unlink,Cint,(Cstring,),path))
                results["rename"] = attempt(() -> ccall(:rename,Cint,(Cstring,Cstring),path,path*".changed"))
                results["mkdir"] = attempt(() -> ccall(:mkdir,Cint,(Cstring,Cuint),path*".dir",0o700))
                results["dup"] = attempt(() -> ccall(:dup,Cint,(Cint,),1))
                results["fork"] = attempt(() -> ccall(:fork,Cint,()))
                results["exec"] = attempt(() -> ccall(:execve,Cint,(Cstring,Ptr{Cvoid},Ptr{Cvoid}),"/bin/true",C_NULL,C_NULL))
                parent = ccall(:getppid,Cint,())
                results["signal_parent"] = attempt(() -> ccall(:kill,Cint,(Cint,Cint),parent,0))
                results["trace_parent"] = attempt(() -> ccall(:ptrace,Clong,(Cuint,Cint,Ptr{Cvoid},Ptr{Cvoid}),16,parent,C_NULL,C_NULL))
                Core.eval(Main, :(compute_child_only_marker = true))
                results["calculation"] = sum(i*i for i in 1:10)
                results
            end
            """
            manager = ProcessManager(;max_handles=1)
            result = ShenScope.run_isolated_compute(ctx,source,[Dict("data"=>Dict("path"=>sentinel),"request"=>Dict())];manager)
            @test result["sandbox"]["enforced"]
            @test result["sandbox"]["thread_synchronized"]
            @test observed == Dict("nnp"=>"1","seccomp"=>"2")
            @test result["results"][1]["calculation"] == 385
            for action in ("open_read","open_write","socket","socketpair","unlink","rename","mkdir","dup","fork","exec","signal_parent","trace_parent")
                @test result["results"][1][action]["value"] == -1
                @test result["results"][1][action]["errno"] == 13
            end
            @test read(sentinel,String) == "retained"
            @test !ispath(sentinel*".changed") && !ispath(sentinel*".dir")
            @test !isdefined(Main,:compute_child_only_marker)
            @test !isdir("/proc/$(child[])")
            @test isempty(manager.handles)
            @test isempty(ctx.budget.reservations)
            @test result["limits"]["address_space_bytes"] == 8*1024^3
            @test result["source_sha256"] == digest(source)
        end
    end
end

@testset "Compute rejection, capacity and lifecycle" begin
    if !ShenScope.compute_seccomp_available()
        @test_skip "Verified Linux/libseccomp compute sandbox unavailable"
    else
        mktempdir() do root
            inputs = [Dict("data"=>Dict(),"request"=>Dict())]
            for (source, expected) in (("selftest() = false\nanalyze(data,request)=Dict()",:analysis),
                    ("function analyze(",:analysis),
                    ("selftest()=true\nanalyze(data,request) = (println(\"protocol corruption\"); Dict())",:compute_protocol),
                    ("selftest()=true\nanalyze(data,request) = Dict(\"x\"=>repeat(\"x\",20000))",:analysis))
                ctx = compute_test_context(root); manager = ProcessManager(;max_handles=1)
                fault = compute_test_failure(() -> ShenScope.run_isolated_compute(ctx,source,inputs;
                    limits=ShenScope.ComputeLimits(;output_bytes=8192),manager))
                @test fault isa ShenScopeError
                @test fault.code == expected
                @test isempty(manager.handles) && isempty(ctx.budget.reservations)
            end
            for category in (:read,:dynamic,:process)
                policy = PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow))
                policy.rules[category] = Deny
                ctx = compute_test_context(root;permissions=policy)
                fault = compute_test_failure(() -> ShenScope.run_isolated_compute(ctx,"selftest()=true\nanalyze(d,r)=Dict()",inputs))
                @test fault isa ShenScopeError && fault.code == :permission
                @test isempty(ctx.budget.reservations)
            end
            for mode in (:cancel,:revoke)
                ctx = compute_test_context(root)
                child = Ref(0)
                ctx.sink = event -> begin
                    if event.kind == :isolated_compute_ready
                        child[] = event.payload["pid"]
                        mode == :cancel ? cancel!(ctx.cancellation,"test cancel") : (ctx.permissions.rules[:dynamic]=Deny)
                    end
                end
                fault = compute_test_failure(() -> ShenScope.run_isolated_compute(ctx,"selftest()=true\nanalyze(d,r)=Dict()",inputs))
                @test fault isa ShenScopeError
                @test fault.code == (mode == :cancel ? :cancelled : :permission)
                @test child[] > 0 && !isdir("/proc/$(child[])")
                @test isempty(ctx.budget.reservations)
            end
            ctx = compute_test_context(root)
            fault = compute_test_failure(() -> ShenScope.run_isolated_compute(ctx,
                "selftest()=true\nanalyze(d,r) = (while true; end)",inputs;
                limits=ShenScope.ComputeLimits(;wall_seconds=0.05)))
            @test fault isa ShenScopeError && fault.code == :timeout
            @test isempty(ctx.budget.reservations)
        end
    end
end

@testset "Inherited descriptors, running cancellation and output flood" begin
    if !ShenScope.compute_seccomp_available()
        @test_skip "Verified Linux/libseccomp compute sandbox unavailable"
    else
        mktempdir() do root
            secret_path = joinpath(root,"private-handle.txt");write(secret_path,"fixture only")
            raw_file = ccall(:open,Cint,(Cstring,Cint),secret_path,0)
            pair = zeros(Cint,2)
            @test raw_file >= 0 && ccall(:pipe,Cint,(Ptr{Cint},),pair) == 0
            inherited_pipe = readlink("/proc/self/fd/$(pair[1])")
            present = String[]
            ctx = compute_test_context(root;sink=event->begin
                if event.kind == :isolated_compute_ready
                    child = event.payload["pid"]
                    for descriptor in readdir("/proc/$child/fd")
                        try push!(present,readlink("/proc/$child/fd/$descriptor")) catch end
                    end
                end
            end)
            inputs = [Dict("data"=>Dict(),"request"=>Dict())]
            try
                result = run_isolated_compute(ctx,"selftest()=true\nanalyze(d,r)=Dict(\"ok\"=>true)",inputs)
                @test result["results"][1]["ok"]
                @test !(secret_path in present)
                @test !(inherited_pipe in present)
            finally
                ccall(:close,Cint,(Cint,),raw_file)
                for descriptor in pair;ccall(:close,Cint,(Cint,),descriptor);end
            end
            manager = ProcessManager(;max_handles=1)
            ctx = compute_test_context(root)
            source = "selftest()=true\nanalyze(d,r)=(println(stderr,\"loopstarted\");flush(stderr);while true; end)"
            task = @async compute_test_failure(() -> run_isolated_compute(ctx,source,inputs;manager))
            entered = false;pid = 0;deadline = time()+45
            while !istaskdone(task) && time() < deadline
                handles = lock(manager.mutex) do;collect(values(manager.handles));end
                if !isempty(handles) && occursin("loopstarted",ShenScope.output_text(first(handles).stderr))
                    entered = true;pid = first(handles).process_id;break
                end
                sleep(0.025)
            end
            cancel!(ctx.cancellation,"cancel active computation")
            fault = fetch(task)
            @test entered
            @test fault isa ShenScopeError && fault.code == :cancelled
            @test pid > 0 && !isdir("/proc/$pid")
            @test isempty(manager.handles) && isempty(ctx.budget.reservations)
            source = "selftest()=true\nanalyze(d,r)=(write(stdout,repeat(\"x\",100000));flush(stdout);Dict())"
            fault = compute_test_failure(() -> run_isolated_compute(compute_test_context(root),source,inputs;
                limits=ComputeLimits(;output_bytes=8192)))
            @test fault isa ShenScopeError && fault.code == :capacity
        end
    end
end
