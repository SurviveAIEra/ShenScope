function hook_script(root, text;name="hook.py")
    path=joinpath(root,name);write(path,text)
    [Sys.which("python3"),"-B","-u",path]
end

function test_configured_hook(manager,ctx,name="guard")
    with_context(()->execute(HooksTool(manager),Dict("action"=>"test","name"=>name),ctx;user_requested=true),ctx)
end

@testset "Real Hook commands have bounded metadata, private output and narrowed environment" begin
    mktempdir() do root
        events=AgentEvent[];ctx=model_context(root);ctx.sink=event->push!(events,event)
        argv=hook_script(root,"""
import json, os, sys
payload=json.load(sys.stdin)
assert 'prompt' not in payload and 'arguments' not in payload
assert 'SHENSCOPE_TEST_INHERITED_KEY' not in os.environ
assert payload['point']=='before_tool' and payload['testing'] is True
open('observed.json','w').write(json.dumps(payload))
print(os.environ['BOUND_KEY'],file=sys.stderr)
print(json.dumps({'decision':'continue','context':'bound '+os.environ['BOUND_KEY'],'reason':os.environ['BOUND_KEY']}))
""")
        entry=hook_entry(argv=argv,allow_context=true,environment_env=Dict("BOUND_KEY"=>"USER_HOOK_KEY"))
        manager=HookManager(hook_test_config([entry]);credential_lookup=key->"unique-private-credential")
        result=withenv("SHENSCOPE_TEST_INHERITED_KEY"=>"must-not-be-inherited") do
            test_configured_hook(manager,ctx)
        end
        @test result["status"] == "complete"
        @test result["reason"] == "[redacted]"
        @test result["context_bytes"] > 0
        payload=parsejson(read(joinpath(root,"observed.json"),String))
        @test payload["session_id"] == ctx.session_id
        @test payload["metadata"] == Dict()
        @test count(event->event.kind == :hook_invoked,events) == 1
        @test count(event->event.kind == :hook_result,events) == 1
        @test !any(event->event.kind == :process_output,events)
        @test !occursin("unique-private-credential",canonical([event.payload for event in events]))
        @test isempty(manager.process.handles) && isempty(manager.active)
        @test budget_status(ctx.budget)["steps"] == 1
        @test isempty(ctx.budget.reservations)
        @test_throws ShenScopeError execute(HooksTool(manager),Dict("action"=>"test","name"=>"guard"),ctx)
        catalog=manager.catalogs[root]
        @test_throws ShenScopeError run_hook!(manager,catalog,catalog.specs[1],ctx;metadata=Dict("prompt"=>"do not expose"))
    end
end

@testset "Hook approval rechecks source identity and current policy before launch" begin
    mktempdir() do root
        argv=hook_script(root,"import json,sys; json.load(sys.stdin); open('launched','w').write('yes'); print('{}')")
        path=hook_file(root,[hook_entry(argv=argv,on_failure="deny")])
        approvals=Ref(0)
        policy=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Ask))
        ctx=RuntimeContext(root;permissions=policy,state_dir=joinpath(root,"state"),approve=request->begin
            approvals[]+=1
            approvals[] == 1 && write(path,read(path,String)*"\n# edited during approval\n")
            :session
        end)
        manager=HookManager(hook_test_config(;project_files=["hooks.toml"]))
        first=test_configured_hook(manager,ctx)
        @test first["status"] == "failed" && first["decision"] == "deny"
        @test !isfile(joinpath(root,"launched"))
        hooks_list(manager,ctx;reload=true)
        second=test_configured_hook(manager,ctx)
        @test second["status"] == "complete"
        @test approvals[] == 2
        @test isfile(joinpath(root,"launched"))
        rm(joinpath(root,"launched"))
        denyctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Ask)),approve=request->begin
            denyctx.permissions.rules[:process]=Deny
            :once
        end)
        @test test_configured_hook(manager,denyctx)["status"] == "denied"
        @test !isfile(joinpath(root,"launched"))
        @test isempty(manager.active) && isempty(manager.process.handles)
    end
end

@testset "Hook timeouts, cancellation, malformed output and bounded history" begin
    mktempdir() do root
        ctx=model_context(root)
        slow=hook_script(root,"import sys,time,json; json.load(sys.stdin); time.sleep(10)")
        manager=HookManager(hook_test_config([hook_entry(argv=slow,timeout=0.1,on_failure="deny")];max_history=2))
        result=test_configured_hook(manager,ctx)
        @test result["status"] == "timed_out" && result["decision"] == "deny"
        @test result["duration_seconds"] < 3
        manager.config=hook_config(hook_test_config([hook_entry(argv=slow,timeout=10.0)];max_history=2))
        hooks_list(manager,ctx;reload=true)
        job=@async test_configured_hook(manager,ctx)
        @test timedwait(()->any(item->item.process !== nothing,values(manager.active)),5) == :ok
        cancel!(ctx.cancellation)
        @test fetch(job)["status"] == "cancelled"
        @test isempty(manager.active) && isempty(manager.process.handles)
        fresh=model_context(root)
        malformed=hook_script(root,"import sys,json; json.load(sys.stdin); print('{\"permissionDecision\":\"allow\"}')";name="bad.py")
        manager.config=hook_config(hook_test_config([hook_entry(argv=malformed)];max_history=2));hooks_list(manager,fresh;reload=true)
        @test test_configured_hook(manager,fresh)["status"] == "failed"
        @test length(manager.history) == 2
        large=hook_script(root,"import sys,json; json.load(sys.stdin); print('A'*300000)";name="large.py")
        bounded=HookManager(hook_test_config([hook_entry(argv=large,output_limit=1024)]))
        result=test_configured_hook(bounded,fresh)
        @test result["status"] == "failed"
        @test result["stdout_bytes"] > 1024
        @test !haskey(result,"stdout") && !haskey(result,"stderr")
        @test !occursin("AAAA",canonical(bounded.history))
        quick=HookManager(hook_test_config([hook_entry(argv=["/bin/true"])]))
        quick_result=test_configured_hook(quick,fresh)
        @test quick_result["status"] == "complete"
        @test quick_result["stdin_written"] isa Bool
        invalid=hook_script(root,"import sys,json; json.load(sys.stdin); sys.stdout.buffer.write(b'{\"context\":\"\\xff\"}')";name="invalid-utf8.py")
        invalid_manager=HookManager(hook_test_config([hook_entry(argv=invalid,allow_context=true)]))
        @test occursin("UTF-8",test_configured_hook(invalid_manager,fresh)["error"])
    end
end

@testset "Actual agent applies Hook context and lifecycle observations without exposing chat" begin
    mktempdir() do root
        ctx=model_context(root)
        argv=hook_script(root,"""
import json,sys
payload=json.load(sys.stdin)
with open('hook-events.jsonl','a') as f: f.write(json.dumps(payload)+'\\n')
print(json.dumps({'context':'inspect verified evidence'} if payload['point']=='before_model' else {}))
""")
        entries=[hook_entry(name=String(point),point=String(point),argv=argv,allow_context=point==:before_model) for point in
            (:session_start,:before_model,:after_model,:before_tool,:after_tool,:after_edit,:after_test,:session_end)]
        manager=HookManager(hook_test_config(entries))
        tools=AbstractTool[WriteTool(),ProcessTool(),HooksTool(manager)]
        provider=MockProvider([response(;calls=[ToolCall("write",Dict("path"=>"created.txt","content"=>"real edit")),
            ToolCall("process",Dict("action"=>"run","purpose"=>"test","argv"=>[Sys.which("python3"),"-c","print('test passed')"]))]),response("Done")])
        session=new_session(ctx)
        @test run_agent!(provider,"private original prompt",ctx;session,tools) == "Done"
        @test read(joinpath(root,"created.txt"),String) == "real edit"
        @test all(request->occursin("inspect verified evidence",request.messages[1].text),provider.requests)
        records=parsejson.(readlines(joinpath(root,"hook-events.jsonl")))
        @test length(records) == 12
        @test first(records)["point"] == "session_start" && last(records)["point"] == "session_end"
        @test last(records)["metadata"]["status"] == "complete"
        @test only(filter(item->item["point"]=="after_test",records))["metadata"]["ok"]
        @test !occursin("private original prompt",canonical(records))
        @test !occursin("real edit",canonical(records))
        @test isempty(manager.active) && isempty(ctx.budget.reservations)
    end
end

@testset "Before-effect Hook denial prevents writes; post-effect failure preserves receipts" begin
    mktempdir() do root
        ctx=model_context(root)
        deny=hook_script(root,"import json,sys; json.load(sys.stdin); print('{\"decision\":\"deny\",\"reason\":\"review first\"}')")
        manager=HookManager(hook_test_config([hook_entry(argv=deny,tools=["write"])]))
        tools=Dict{String,AbstractTool}("write"=>WriteTool(),"hooks"=>HooksTool(manager))
        call=ToolCall("write",Dict("path"=>"denied.txt","content"=>"must not exist"))
        result=only(execute_batch(tools,[call],ctx))
        @test !result.ok
        @test !isfile(joinpath(root,"denied.txt"))
        bad=hook_script(root,"import json,sys; json.load(sys.stdin); print('{\"decision\":\"deny\"}')";name="post.py")
        manager.config=hook_config(hook_test_config([hook_entry(argv=bad,point="after_edit")]))
        hooks_list(manager,ctx;reload=true)
        result=only(execute_batch(tools,[call],ctx))
        @test result.ok
        @test read(joinpath(root,"denied.txt"),String) == "must not exist"
        @test last(manager.history)["status"] == "failed"
        @test last(manager.history)["decision"] == "continue"
        stop=hook_script(root,"import json,sys; json.load(sys.stdin); print('{\"decision\":\"stop\"}')";name="stop.py")
        stopped=HookManager(hook_test_config([hook_entry(argv=stop)]))
        provider=MockProvider([response(;calls=[ToolCall("write",Dict("path"=>"stopped.txt","content"=>"none"))]),response("not reached")])
        session=new_session(ctx)
        @test_throws ShenScopeError run_agent!(provider,"test stop",ctx;session,tools=AbstractTool[WriteTool(),HooksTool(stopped)])
        @test !isfile(joinpath(root,"stopped.txt"))
        @test length(provider.requests) == 1
        @test session.status == :interrupted
        @test length(session.messages) == 3
    end
end

@testset "Owned processes drain descendants and bound blocked stdin" begin
    mktempdir() do root
        ctx=model_context(root);manager=ProcessManager()
        argv=hook_script(root,"""
import subprocess,sys
child=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)'])
open('descendant.pid','w').write(str(child.pid))
print('leader complete')
""")
        handle=ShenScope.start_process!(manager,argv,ctx;timeout=3)
        close(handle.input)
        @test timedwait(()->istaskdone(handle.monitor),3) == :ok
        @test occursin("leader complete",ShenScope.process_status(handle)["stdout"])
        descendant=parse(Int,read(joinpath(root,"descendant.pid"),String))
        status_path="/proc/" * string(descendant) * "/status"
        @test !isfile(status_path) || occursin(r"State:\s+[ZX]",read(status_path,String))
        blocked=ShenScope.start_process!(manager,[Sys.which("python3"),"-c","import time; time.sleep(5)"],ctx;timeout=0.1)
        @test_throws ShenScopeError ShenScope.process_input!(blocked,"A"^900000,ctx)
        @test timedwait(()->istaskdone(blocked.monitor),3) == :ok
        @test isvalid(ShenScope.process_utf8(UInt8[0xff,0xe4,0xb8,0xad]))
        cleanup_processes!(manager,ctx.session_id)
        @test isempty(manager.handles)
        budgetctx=RuntimeContext(root;budget=BudgetLedger(BudgetLimits(;max_seconds=0.8)),
            permissions=PermissionPolicy(;rules=Dict(:process=>Ask)),approve=request->begin sleep(0.4);:once;end)
        bounded=try
            running=ShenScope.start_process!(manager,[Sys.which("python3"),"-c","import time;time.sleep(5)"],budgetctx;timeout=10)
            wait(running.monitor)
            ShenScope.process_status(running)
        catch cause
            cause
        end
        @test bounded isa ShenScopeError ? bounded.code == :budget : bounded["timed_out"] && bounded["elapsed_seconds"] < 0.8
        cleanup_processes!(manager,budgetctx.session_id)
    end
end
