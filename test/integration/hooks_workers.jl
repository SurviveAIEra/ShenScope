@testset "Actual durable workers persist Hook effects and serialize unknown command checks" begin
    mktempdir() do root
        ctx=work_context(root)
        write(joinpath(root,"source.txt"),"worker evidence")
        argv=hook_script(root,"import json,sys; json.load(sys.stdin); print('{}')")
        manager=HookManager(hook_test_config([hook_entry(argv=argv)]))
        executor=WorkExecutor(;tools=AbstractTool[ReadTool(),HooksTool(manager)])
        workflow=create_workflow(ctx,[read_work("a"),read_work("b")];id="hooks-parallel")
        @test run_workflow!(executor,workflow,ctx;concurrency=4)["status"] == "succeeded"
        @test length(manager.history) == 2
        @test all(item->item["status"] == "complete",manager.history)
        @test all(record->last(record.receipts).hooks_started && last(record.receipts).hooks_barrier,values(workflow.tasks))
        @test all(record->last(record.receipts).hooks_started,values(load_workflow(ctx,workflow.id).tasks))
        modelmanager=HookManager(hook_test_config([hook_entry(name="model-check",point="session_start",argv=argv)]))
        model=create_workflow(ctx,[WorkSpec("agent",:model,"agent",Dict("prompt"=>"hello"))];id="hook-model")
        modelworker=WorkExecutor(;tools=AbstractTool[HooksTool(modelmanager)],provider_factory=ctx->MockProvider([response("hello")]))
        @test run_workflow!(modelworker,model,ctx)["status"] == "succeeded"
        @test last(model.tasks["agent"].receipts).hooks_started
        @test last(modelmanager.history)["session_id"] != ctx.session_id
        slow=hook_script(root,"import json,sys,time; json.load(sys.stdin); open('hook-counter','a').write('once\\n'); time.sleep(5)";name="slow-worker.py")
        guarded=HookManager(hook_test_config([hook_entry(argv=slow,on_failure="deny",timeout=0.1)]))
        retry=WorkRetryPolicy(;max_attempts=2,initial_delay=0.0,maximum_delay=0.0)
        failure=create_workflow(ctx,[read_work("read";retry)];id="hook-interrupted")
        @test run_workflow!(WorkExecutor(;tools=AbstractTool[ReadTool(),HooksTool(guarded)]),failure,ctx)["status"] == "needs_reconciliation"
        @test failure.tasks["read"].attempts == 1
        @test readlines(joinpath(root,"hook-counter")) == ["once"]
        @test failure.tasks["read"].failure.effects_uncertain
    end
end

@testset "Lost leases cannot silently replay declared Hook effects or accept foreign markers" begin
    mktempdir() do root
        ctx=work_context(root)
        retry=WorkRetryPolicy(;max_attempts=2,initial_delay=0.0,maximum_delay=0.0)
        workflow=create_workflow(ctx,[read_work("a";retry),read_work("b";retry)];id="hook-fences")
        record=claim_work!(workflow,ctx;worker="owner",hooks_barrier=true,lease_seconds=5,now=100.0)
        @test claim_work!(workflow,ctx;worker="peer",now=100.1) === nothing
        start_work!(workflow,ctx,record.spec.id;worker="owner",token=record.lease.token,now=100.2)
        @test_throws ShenScopeError ShenScope.mark_work_hook_effect!(workflow,ctx,record.spec.id;worker="peer",token=record.lease.token,hook_id="guard",now=100.3)
        ShenScope.mark_work_hook_effect!(workflow,ctx,record.spec.id;worker="owner",token=record.lease.token,hook_id="guard",now=100.3)
        receipt=last(load_workflow(ctx,workflow.id).tasks[record.spec.id].receipts)
        @test receipt.phase == :hook_started && receipt.hooks_started
        recover_workflow!(workflow,ctx;now=106.0)
        @test workflow.tasks[record.spec.id].status == WorkUncertain
        @test workflow.tasks[record.spec.id].failure.effects_uncertain
        @test workflow.tasks[record.spec.id].attempts == 1
        old=ShenScope.work_receipt_dict(ShenScope.WorkReceipt("legacy",1,:started,1.0,nothing,nothing,""))
        delete!(old,"hooks_started");delete!(old,"hooks_barrier")
        @test !ShenScope.work_receipt_from(old).hooks_started
        old["hooks_started"]="false"
        @test_throws ShenScopeError ShenScope.work_receipt_from(old)
    end
end

@testset "Hooks CLI uses the same commands, permissions and failure status" begin
    mktempdir() do root
        argv=hook_script(root,"import json,sys; json.load(sys.stdin); open('cli-hook','w').write('verified'); print('{}')")
        config=deepcopy(ShenScope.DEFAULT_CONFIG)
        config["hooks"]=Dict("entries"=>[hook_entry(argv=argv)],"project_files"=>[],"user_files"=>[])
        path=joinpath(root,"config.toml");save_config!(config;path)
        output=joinpath(root,"cli-output.json")
        flags=["--root",root,"--state-dir",joinpath(root,"state"),"--config",path]
        open(output,"w") do io
            @test redirect_stdout(()->ShenScope.main(vcat(["hooks","test","guard","--allow-process"],flags)),io) == 0
        end
        @test parsejson(read(output,String))["status"] == "complete"
        @test read(joinpath(root,"cli-hook"),String) == "verified"
        config["permissions"]["process"]="deny";save_config!(config;path)
        open(output,"w") do io
            @test redirect_stdout(()->ShenScope.main(vcat(["hooks","test","guard"],flags)),io) == 2
        end
        @test parsejson(read(output,String))["status"] == "denied"
        @test read(joinpath(root,"cli-hook"),String) == "verified"
    end
end
