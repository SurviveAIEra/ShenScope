@testset "Actual agent failure, hash edit and rerun in five project languages" begin
    for language in ("python","javascript","go","c","cpp")
        @testset "$language project repair" begin
            mktempdir() do root
                fixture=project_testing_fixture(root,language);events=AgentEvent[]
                ctx=project_testing_context(root;sink=event->push!(events,event));tools=core_tools()
                try
                    if !isempty(fixture.compile)
                        setup=execute(only(tool for tool in tools if tool isa ProcessTool),Dict("action"=>"run","argv"=>fixture.compile),ctx)
                        @test setup["exit_code"]==0
                    end
                    test_arguments=Dict("action"=>"custom","argv"=>fixture.command,"framework"=>fixture.framework,"timeout"=>90)
                    rerun=ToolCall[]
                    isempty(fixture.compile) || push!(rerun,ToolCall("process",Dict("action"=>"run","argv"=>fixture.compile)))
                    push!(rerun,ToolCall("testing",test_arguments))
                    provider=MockProvider(Any[
                        response(;calls=[ToolCall("testing",test_arguments)]),response(;calls=[ToolCall("read",Dict("path"=>fixture.path))]),
                        response(;calls=[ToolCall("edit",Dict("path"=>fixture.path,"old"=>"a-b","new"=>"a+b","expected_sha256"=>digest(fixture.broken)))]),
                        response(;calls=rerun),response("The selected addition test command now exits successfully.")])
                    session=new_session(ctx;title=language*" project repair")
                    run_agent!(provider,"Fix addition and verify the selected project tests",ctx;session,tools)
                    results=[event.payload for event in events if event.kind==:tool_completed && event.payload["name"]=="testing"]
                    @test length(results)==2 && !results[1]["ok"] && results[2]["ok"]
                    first=results[1]["value"];last=results[2]["value"]
                    @test first["outcome"]=="command_failed" && first["exit_code"]!=0
                    @test last["outcome"]=="command_succeeded" && last["exit_code"]==0
                    @test !isempty(first["parsed"]["frames"])
                    if fixture.framework!="raw"
                        @test first["parsed"]["observed_case_counts"]["failed"]>=1
                        @test last["parsed"]["observed_case_counts"]["passed"]>=1
                    end
                    @test !last["parsed"]["complete_project_coverage"] && !last["execution_source_snapshot_verified"]
                    @test read(joinpath(root,fixture.path),String)==replace(fixture.broken,"a-b"=>"a+b")
                    saved=load_session(ctx.state_dir,session.id)
                    receipts=[parsejson(message.text)["value"] for message in saved.messages if message.role==:tool &&
                        get(parsejson(message.text),"value",nothing) isa AbstractDict && haskey(parsejson(message.text)["value"],"run_id")]
                    @test length(receipts)==2 && receipts[end]["sha256"]==last["sha256"]
                    @test digest(canonical(ShenScope.project_test_report_body(last)))==last["sha256"]
                finally
                    for tool in tools
                        tool isa TestingTool && (close_operations!(tool.operations);cleanup_project_tests!(tool.manager))
                        tool isa ProcessTool && cleanup_processes!(tool.manager,ctx.session_id)
                    end
                end
            end
        end
    end
end

@testset "Framework failure with zero exit remains a failed tool and after-test check" begin
    mktempdir() do root
        ctx=project_testing_context(root);tool=TestingTool()
        script="import json,sys;value=json.load(sys.stdin);open('after-test.json','w').write(json.dumps(value['metadata']));print('{}')"
        config=Dict("hooks"=>Dict("project_files"=>String[],"user_files"=>String[],"entries"=>[
            Dict("name"=>"capture","point"=>"after_test","argv"=>["python3","-c",script])]))
        manager=HookManager(config)
        result=ShenScope.with_lifecycle_hooks(AbstractTool[tool,HooksTool(manager)],ctx) do
            execute_call(tool,ToolCall("testing",Dict("action"=>"custom","framework"=>"tap",
                "argv"=>["python3","-c","print('not ok 1 - failed case\\n1..1')"])),ctx)
        end
        @test !result.ok && result.value["exit_code"]==0 && result.value["outcome"]=="reported_failure"
        metadata=parsejson(read(joinpath(root,"after-test.json"),String))
        @test metadata["ok"]==false && metadata["exit_code"]==0 && metadata["tool"]=="testing"
        @test length(manager.history)==1
        cleanup_hooks!(manager);close_operations!(tool.operations);cleanup_project_tests!(tool.manager)
    end
end

@testset "Selected declarations rechecked after approval; read/process gates and current source" begin
    mktempdir() do root
        fixture=project_testing_fixture(root,"python");ctx=project_testing_context(root);manager=ProjectTestManager()
        catalog=discover_project_tests!(manager,ctx);candidate=only(catalog["candidates"])
        original=read(joinpath(root,"pyproject.toml"),String)
        ctx.permissions.rules[:process]=Ask
        ctx.approve=request->begin write(joinpath(root,"pyproject.toml"),original*"# changed during approval\n");:once end
        @test_throws ShenScopeError run_project_tests!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_id=candidate["id"])
        @test isempty(manager.reports) && isempty(manager.processes.handles)
        ctx.permissions.rules[:process]=Deny;write(joinpath(root,"pyproject.toml"),original)
        @test_throws ShenScopeError run_project_tests!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_id=candidate["id"])
        ctx.permissions.rules[:process]=Allow
        report=run_project_tests!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_id=candidate["id"])
        @test report["command"]["confidence"]=="heuristic" && report["exit_code"]==1
        frame=only(filter(value->value["path"]=="test_calc.py",report["parsed"]["frames"]))
        source=read_project_test_source(manager,report["run_id"],frame["id"],ctx)
        @test source["sha256"]==digest(read(joinpath(root,"test_calc.py"),String)) && !source["execution_source_snapshot_verified"]
        @test any(line->line["reported"] && line["line"]==frame["line"],source["lines"])
        write(joinpath(root,"test_calc.py"),read(joinpath(root,"test_calc.py"),String)*"# source changed\n")
        @test_throws ShenScopeError read_project_test_source(manager,report["run_id"],frame["id"],ctx;expected_sha256=source["sha256"])
        @test_throws ShenScopeError read_project_test_source(manager,report["run_id"],repeat("0",64),ctx)
        @test_throws ShenScopeError read_project_test_report(manager,report["run_id"],project_testing_context(root))
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError read_project_test_report(manager,report["run_id"],ctx)
        ctx.permissions.rules[:read]=Allow
        list=list_project_test_reports(manager,ctx)
        @test length(list["reports"])==1 && !list["survives_server_restart"] && !list["automatic_replay"]
        cleanup_project_tests!(manager)
    end
end

@testset "Execution timeout, cancellation, revocation, output and retention bounds" begin
    mktempdir() do root
        ctx=project_testing_context(root);manager=ProjectTestManager(;max_reports=2)
        no_tests=run_project_test_command!(manager,ctx;argv=["python3","-m","unittest","discover","-v"],framework="unittest")
        @test no_tests["parsed"]["framework_summary"]["tests"]==0 && !no_tests["parsed"]["complete_project_coverage"]
        @test !no_tests["parsed"]["individual_cases_observed"]
        large=run_project_test_command!(manager,ctx;argv=["python3","-c","print('x'*4096)"],output_limit=64)
        @test large["process"]["stdout_truncated"] && large["process"]["stdout_bytes"]==4097
        @test !large["parsed"]["captured_streams_complete"] && !large["parsed"]["interpretation_complete"]
        timed=run_project_test_command!(manager,ctx;argv=["python3","-c","import time;time.sleep(10)"],timeout=0.1)
        @test timed["outcome"]=="timed_out" && timed["timed_out"]
        @test_throws ShenScopeError read_project_test_report(manager,no_tests["run_id"],ctx)
        for kind in (:cancel,:process,:read)
            operation=project_testing_context(root)
            flag="started-"*String(kind)
            script="from pathlib import Path;import time;Path('"*flag*"').write_text('one');time.sleep(0.3);print('done')"
            job=@async run_project_test_command!(manager,operation;argv=["python3","-c",script],timeout=5)
            @test timedwait(()->isfile(joinpath(root,flag)),10;pollint=0.01)==:ok
            if kind==:cancel;cancel!(operation.cancellation,"fixture cancellation")
            elseif kind==:process;operation.permissions.rules[:process]=Deny
            else;operation.permissions.rules[:read]=Deny;end
            if kind==:read
                @test_throws TaskFailedException fetch(job)
                operation.permissions.rules[:read]=Allow
                reports=list_project_test_reports(manager,operation)
                @test length(reports["reports"])==1
            else
                value=fetch(job)
                @test value["outcome"]==(kind==:cancel ? "cancelled" : "permission_revoked")
            end
            @test read(joinpath(root,flag),String)=="one" && isempty(manager.processes.handles)
        end
        cleanup_project_tests!(manager)
    end
end
