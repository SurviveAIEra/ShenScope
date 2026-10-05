@testset "Compiler graph workers honor approvals, revocation and restricted execution" begin
    mktempdir() do root
        approvals=Symbol[]
        ctx=RuntimeContext(root;approve=request->(push!(approvals,request.category);:once))
        result=run_compiler_diagnostic(ctx,"digest_string";mode="graph",timeout=120)
        @test approvals==[:dynamic,:process]
        @test result["report"]["schema"]==ShenScope.COMPILER_IR_SCHEMA
        @test result["report"]["methods"][1]["return_type"]["type"]=="String"
        @test result["execution"]["separate_process"] && !result["execution"]["os_sandbox"]
        @test !result["report"]["effects"]["safety_boundary"]
        denied=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Deny,:process=>Allow)))
        @test_throws ShenScopeError run_compiler_diagnostic(denied,"digest_string";mode="graph")
        restricted=RuntimeContext(root;sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy()),
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow)))
        @test_throws ShenScopeError run_compiler_diagnostic(restricted,"digest_string";mode="graph")
        reference=Ref{RuntimeContext}()
        revoked=RuntimeContext(root;approve=request->begin
            request.category==:process && (reference[].permissions.rules[:dynamic]=Deny)
            :once
        end)
        reference[]=revoked
        started=time()
        @test_throws ShenScopeError run_compiler_diagnostic(revoked,"digest_string";mode="graph",timeout=120)
        @test time()-started<15
        reading=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Deny,:dynamic=>Allow,:process=>Allow)))
        @test_throws ShenScopeError run_compiler_diagnostic(reading,"digest_string";mode="typed")
        @test_throws ShenScopeError run_compiler_diagnostic(ctx,"digest_string";mode="graph",timeout=Inf)
    end
end

@testset "Compiler polling closes actual helpers after live denial and cancellation" begin
    mktempdir() do root
        for action in (:read,:dynamic,:cancel)
            ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow)))
            project=ShenScope.runtime_core_root()
            worker=ShenScope.BackendWorker([first(Base.julia_cmd().exec),"--startup-file=no","--history-file=no",
                "--compiled-modules=existing","--threads=1","--project="*project,
                "-e","using ShenScope;exit(ShenScope.compiler_worker_main())"])
            mutation=nothing
            try
                ShenScope.worker_start!(worker,ctx;reason="Verify cancellation of the actual compiler helper")
                process=worker.process
                @test process!==nothing && !process_exited(process)
                mutation=@async begin
                    sleep(0.2)
                    if action==:cancel
                        cancel!(ctx.cancellation,"Compiler polling fixture")
                    else
                        lock(ctx.permissions.mutex) do;ctx.permissions.rules[action]=Deny;end
                    end
                end
                checkpoint=()->ShenScope.compiler_diagnostic_checkpoint(ctx,"canonical_dictionary")
                started=time()
                cause=try
                    ShenScope.worker_request(worker,"compiler",Dict("target"=>"canonical_dictionary","mode"=>"typed"),ctx;
                        timeout=120,checkpoint)
                    nothing
                catch error;error end
                wait(mutation)
                @test cause isa ShenScopeError
                @test cause.code==(action==:cancel ? :cancelled : :permission)
                @test time()-started<10
                @test worker.process===nothing && process_exited(process)
            finally
                mutation===nothing || wait(mutation)
                ShenScope.worker_close!(worker;force=true)
            end
        end
    end
end
