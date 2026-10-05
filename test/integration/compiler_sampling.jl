@testset "Sampling helpers use scoped approvals and owned reports join source facts without reexecution" begin
    mktempdir() do root
        approvals=Symbol[];ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
            approve=request->(push!(approvals,request.category);:once))
        tool=DiagnosticsTool()
        job=start_operation!(tool.operations,ctx;kind="sample",metadata=Dict("mode"=>"sampling")) do operation
            execute(tool,Dict("action"=>"sample","target"=>"cliptext_string","duration_seconds"=>0.1,
                "max_samples"=>32,"max_frames"=>3,"timeout"=>120),operation)
        end
        completed=await_owned_operation(tool.operations,job["job_id"];timeout=120)
        @test completed.status==:complete
        report=completed.result["report"]
        @test approvals==[:dynamic,:process] && report["runtime"]["threads"]==1
        @test completed.result["execution"]["separate_process"] && !completed.result["execution"]["os_sandbox"]
        @test report["sampling_summary"]["observed_backtraces"]>0
        @test report["sampling_summary"]["backtraces_with_core_frames"]>0
        ctx.permissions.rules[:dynamic]=Deny;ctx.permissions.rules[:process]=Deny
        args=Dict("action"=>"evidence","sampling_job_id"=>job["job_id"],"observation_kind"=>"sampling","limit"=>128)
        page=execute(tool,args,ctx)
        @test only(page["report_stamps"])["kind"]=="sampling" && page["profile_summary"]===nothing
        @test page["summary"]["observation_kinds"]["sampling"]>=length(report["samples"])
        @test !page["summary"]["sampling_frame_occurrences_are_additive"] && !page["sampling_summary"]["sampling"]["cpu_utilization_measured"]
        row=first(row for row in page["items"] if row["source"]["file"]!==nothing)
        @test row["details"]["periodic_backtrace_observed"] && !row["details"]["selected_target_binding_confirmed"]
        preview=execute(tool,Dict("action"=>"evidence_source","sampling_job_id"=>job["job_id"],"observation_key"=>row["key"],
            "expected_evidence_sha256"=>page["evidence_sha256"]),ctx)
        @test preview["observation_kind"]=="sampling" && preview["source_sha256"]==row["source"]["source_sha256"]
        compiler=ShenScope.compiler_ir_report("cliptext_string");snapshot=runtime_source_snapshot(ctx)
        both=ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx;sampling=report)
        @test getindex.(both.report_stamps,"kind")==["compiler","sampling"]
        @test both.summary["observation_kinds"]["statement"]>40 && both.summary["observation_kinds"]["sampling"]>0
        @test_throws ShenScopeError ShenScope.runtime_evidence_build(ShenScope.compiler_ir_report("digest_string"),nothing,snapshot,ctx;sampling=report)
        wrong=RuntimeContext(root;session_id="foreign",permissions=ctx.permissions,state_dir=ctx.state_dir)
        @test_throws ShenScopeError execute(tool,args,wrong)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"evidence","profile_job_id"=>job["job_id"]),ctx)
        for category in (:read,:dynamic,:process)
            rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow);rules[category]=Deny
            @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(RuntimeContext(root;permissions=PermissionPolicy(;rules)),"digest_string")
        end
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(ctx,"remove_graph_edge")
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(ctx,"digest_string";timeout=true)
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(ctx,"digest_string";duration_seconds=Inf)
        restricted=RuntimeContext(root;sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy()))
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(restricted,"digest_string")
        reference=Ref{RuntimeContext}()
        revoked=RuntimeContext(root;approve=request->begin
            request.category==:process && (reference[].permissions.rules[:dynamic]=Deny);:once
        end)
        reference[]=revoked
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(revoked,"digest_string";timeout=120)
        timeout=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow)))
        @test_throws ShenScopeError ShenScope.run_sampling_diagnostic(timeout,"digest_string";timeout=0.1)
        close_operations!(tool.operations)
    end
end

@testset "CLI and real agent share fixed Core periodic sampling" begin
    mktempdir() do root
        state=joinpath(root,"state");config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\ndynamic='allow'\nprocess='allow'\npersistence='allow'\nnetwork='deny'\n")
        entry="using ShenScope;exit(ShenScope.main(ARGS))"
        command=`$(Base.julia_cmd()) --startup-file=no --project=$(ShenScope.runtime_core_root()) -e $entry -- diagnostics sample canonical_dictionary --iterations 1 --duration 0.03 --sample-delay 0.002 --max-samples 8 --max-frames 2 --profile-buffer-words 4096 --timeout 120 --root $root --config $config --state-dir $state`
        data=parsejson(read(command,String))
        @test data["report"]["schema"]==ShenScope.COMPILER_SAMPLING_SCHEMA
        @test data["report"]["limits"]["delay_seconds"]==0.002 && data["report"]["limits"]["buffer_words"]==4096
        @test data["report"]["fixture"]["name"]=="nested_dictionary" && data["report"]["runtime"]["threads"]==1
        tool=DiagnosticsTool();ctx=RuntimeContext(root;state_dir=state,permissions=PermissionPolicy(;rules=Dict(
            :read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow)))
        session=new_session(ctx)
        args=Dict("action"=>"sample","target"=>"digest_string","duration_seconds"=>0.03,"max_samples"=>4,"max_frames"=>2,"timeout"=>120)
        provider=MockProvider([response(;calls=[ToolCall("diagnostics",args)]),response("Sampled fixed Core backtraces.")])
        @test run_agent!(provider,"Sample a fixed Core fixture",ctx;session,tools=[tool])=="Sampled fixed Core backtraces."
        observed=only(parsejson(message.text) for message in session.messages if message.role==:tool)
        @test observed["ok"] && observed["value"]["report"]["runtime_execution_observed"]
        @test length(provider.requests)==2 && session.status==:complete
        close_operations!(tool.operations)
    end
end
