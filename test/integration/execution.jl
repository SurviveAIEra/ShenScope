@testset "Kernel network filters, descriptor closure and native child commands" begin
    if Sys.islinux() && ShenScope.compute_seccomp_available()
        root,ctx=execution_fixture();manager=ProcessManager(;max_handles=1)
        try
            policy=ShenScope.ExecutionPolicy(;limits=ShenScope.ExecutionLimits(;cpu_seconds=10))
            nonce=repeat("a",64);sha=repeat("b",64)
            script="""
                import os,socket,subprocess
                denied=0
                for family in [socket.AF_INET,socket.AF_INET6,socket.AF_UNIX]:
                    try: socket.socket(family); raise RuntimeError('socket escaped')
                    except PermissionError: denied+=1
                try: socket.socketpair(); raise RuntimeError('socketpair escaped')
                except PermissionError: denied+=1
                inherited=[]
                for fd in os.listdir('/proc/self/fd'):
                    if int(fd)<=2: continue
                    try: os.fstat(int(fd)); inherited.append(fd)
                    except OSError: pass
                assert inherited==[],inherited
                assert subprocess.check_output(['/usr/bin/printf','native child'])==b'native child'
                print('kernel_denials='+str(denied)+' inherited_descriptors=0 child_verified=true')
                """
            argv=ShenScope.execution_worker_arguments(policy,nonce,sha,["/usr/bin/python3","-c",script];
                backend="network_probe",worker=ShenScope.execution_worker_path())
            h=ShenScope.start_process!(manager,argv,ctx;timeout=20,emit_output=false,
                environment=Dict(ShenScope.execution_environment(policy;source=Dict())))
            close(h.input);wait(h.monitor);result=ShenScope.process_status(h)
            @test result["exit_code"]==0 && result["signal"]==0
            @test occursin("kernel_denials=4 inherited_descriptors=0 child_verified=true",result["stdout"])
            @test startswith(result["stderr"],"SHENSCOPE_EXEC_READY:"*nonce*":"*sha*":network_probe\n")
            @test !result["sandbox"]["os_isolation"] # This fixture verifies network-only worker restrictions.
        finally
            cleanup_processes!(manager,ctx.session_id);rm(root;recursive=true)
        end
    end
end

@testset "Kernel execution resource limits preserve truthful signal status" begin
    if Sys.islinux() && ShenScope.compute_seccomp_available()
        root,ctx=execution_fixture();manager=ProcessManager(;max_handles=1)
        try
            policy=ShenScope.ExecutionPolicy(;limits=ShenScope.ExecutionLimits(;cpu_seconds=1,file_bytes=65536))
            output=joinpath(root,"bounded.bin")
            script="""
                import os
                try:
                    with open('$output','wb',buffering=0) as f: f.write(b'x'*131072); f.write(b'x')
                except OSError: print('file limit enforced')
                assert os.path.getsize('$output')<=65536
                """
            argv=ShenScope.execution_worker_arguments(policy,repeat("c",64),repeat("d",64),["/usr/bin/python3","-c",script];
                backend="network_probe",worker=ShenScope.execution_worker_path())
            h=ShenScope.start_process!(manager,argv,ctx;timeout=20,emit_output=false);close(h.input);wait(h.monitor)
            @test ShenScope.process_status(h)["exit_code"]==0
            @test filesize(output)<=65536 && occursin("file limit enforced",ShenScope.process_status(h)["stdout"])
            cleanup_processes!(manager,ctx.session_id)
            spin=ShenScope.execution_worker_arguments(policy,repeat("e",64),repeat("f",64),["/usr/bin/python3","-c","while True: pass"];
                backend="network_probe",worker=ShenScope.execution_worker_path())
            h=ShenScope.start_process!(manager,spin,ctx;timeout=20,emit_output=false);close(h.input);wait(h.monitor)
            status=ShenScope.process_status(h)
            @test status["signal"] in (9,24) && status["exit_code"]==-status["signal"]
            @test !status["timed_out"]
        finally
            cleanup_processes!(manager,ctx.session_id);rm(root;recursive=true)
        end
    end
end

@testset "Unavailable isolation never executes the requested payload on host" begin
    root,ctx=execution_fixture();manager=ProcessManager(;max_handles=1)
    try
        probe=ShenScope.execution_probe_backend(ctx)
        if Sys.islinux()
            ctx.sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy())
            marker=joinpath(root,"host-escape-marker")
            script="from pathlib import Path;Path('$marker').write_text('unexpected effect')"
            if probe.state!=:available
                @test_throws ShenScopeError ShenScope.start_process!(manager,["/usr/bin/python3","-c",script],ctx)
                @test !isfile(marker) && isempty(manager.handles)
                println("Full namespace execution unavailable here; verified refusal: ",probe.reason)
            else
                script="""
                    import socket
                    from pathlib import Path
                    denied=0
                    for path in ['$marker','/etc/shenscope-write-probe']:
                        try: Path(path).write_text('unexpected effect')
                        except (PermissionError,FileNotFoundError,OSError): denied+=1
                    try: socket.socket()
                    except PermissionError: denied+=1
                    assert denied==3,denied
                    print('filesystem and network isolation verified')
                    """
                h=ShenScope.start_process!(manager,["/usr/bin/python3","-c",script],ctx;timeout=20,emit_output=false)
                close(h.input);wait(h.monitor);status=ShenScope.process_status(h)
                @test status["exit_code"]==0 && status["sandbox"]["os_isolation"]
                @test occursin("filesystem and network isolation verified",status["stdout"])
                @test !isfile(marker)
                println("Full namespace execution available and independently exercised")
            end
        else
            @test probe.state==:unsupported_platform
        end
    finally
        cleanup_processes!(manager,ctx.session_id);rm(root;recursive=true)
    end
end

@testset "Revoked process permission terminates an owned process tree" begin
    root,ctx=execution_fixture();manager=ProcessManager(;max_handles=1)
    try
        h=ShenScope.start_process!(manager,["/usr/bin/python3","-c","import time;print('started',flush=True);time.sleep(30)"],ctx;emit_output=false)
        @test timedwait(()->occursin("started",ShenScope.output_text(h.stdout)),5;pollint=0.01)==:ok
        lock(ctx.permissions.mutex) do;ctx.permissions.rules[:process]=Deny;end
        @test timedwait(()->istaskdone(h.monitor),5;pollint=0.01)==:ok
        result=ShenScope.process_status(h)
        @test result["permission_revoked"] && !result["timed_out"] && result["exit_code"]<0
        @test h.terminated && !result["running"]
    finally
        cleanup_processes!(manager,ctx.session_id);rm(root;recursive=true)
    end
end

@testset "A kernel-interrupted durable task retains uncertain file effects" begin
    if Sys.islinux() && ShenScope.compute_seccomp_available()
        root,ctx=execution_fixture(;rules=Dict(:read=>Allow,:process=>Allow,:persistence=>Allow))
        executor=WorkExecutor(;tools=[ProcessTool()])
        try
            marker=joinpath(root,"task-effect.txt")
            policy=ShenScope.ExecutionPolicy(;limits=ShenScope.ExecutionLimits(;cpu_seconds=1))
            script="from pathlib import Path;Path('$marker').write_text('one effect');\nwhile True: pass"
            argv=ShenScope.execution_worker_arguments(policy,repeat("1",64),repeat("2",64),["/usr/bin/python3","-c",script];
                backend="network_probe",worker=ShenScope.execution_worker_path())
            spec=WorkSpec("cpu",:test,"process",Dict("action"=>"run","argv"=>argv))
            workflow=create_workflow(ctx,[spec];id="kernel-effect")
            run_workflow!(executor,workflow,ctx)
            stored=load_workflow(ctx,workflow.id).tasks["cpu"]
            @test stored.status==ShenScope.WorkUncertain
            @test stored.failure.code==:process_interrupted && stored.failure.effects_uncertain
            @test read(marker,String)=="one effect" && length(stored.receipts)==1
        finally
            ShenScope.cleanup_executor!(executor,ctx.session_id);rm(root;recursive=true)
        end
    end
end
