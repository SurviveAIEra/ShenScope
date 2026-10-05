@testset "Owned runtime evidence joins actual helper allocations and compiler facts without execution" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(
            :read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Deny,:edit=>Deny,:network=>Deny)))
        tool=DiagnosticsTool()
        compiler=ShenScope.compiler_ir_report("cliptext_string")
        inferred=start_operation!(tool.operations,ctx;kind="compile",metadata=Dict("mode"=>"graph")) do operation
            Dict("report"=>compiler)
        end
        await_owned_operation(tool.operations,inferred["job_id"])
        sampled=start_operation!(tool.operations,ctx;kind="profile",metadata=Dict("mode"=>"profile")) do operation
            ShenScope.run_profile_diagnostic(operation,"cliptext_string";iterations=2,repetitions=1,max_samples=12,max_frames=3,timeout=120)
        end
        completed=await_owned_operation(tool.operations,sampled["job_id"];timeout=120)
        @test completed.status==:complete
        ctx.permissions.rules[:dynamic]=Deny;ctx.permissions.rules[:process]=Deny
        args=Dict("action"=>"evidence","compiler_job_id"=>inferred["job_id"],"profile_job_id"=>sampled["job_id"],"limit"=>128)
        page=execute(tool,args,ctx)
        @test length(page["report_stamps"])==2 && page["profile_summary"]["allocation"]["retained_samples"]==12
        @test page["summary"]["observation_kinds"]["allocation"]>=12
        @test sum(values(page["summary"]["join_statuses"]))==page["summary"]["observations"]
        allocation=first(row for row in page["items"] if row["kind"]=="allocation" && row["source"]["file"]!==nothing)
        @test allocation["details"]["sampled_allocation_observed"] && !allocation["details"]["selected_target_binding_confirmed"]
        source_args=Dict(key=>value for (key,value) in args if key!="limit")
        preview=execute(tool,merge(source_args,Dict("action"=>"evidence_source","observation_key"=>allocation["key"],
            "expected_evidence_sha256"=>page["evidence_sha256"])),ctx)
        @test preview["observation_kind"]=="allocation" && preview["source_sha256"]==allocation["source"]["source_sha256"]
        profile_only=execute(tool,Dict("action"=>"evidence","profile_job_id"=>sampled["job_id"]),ctx)
        @test length(profile_only["report_stamps"])==1 && profile_only["summary"]["observation_kinds"]["statement"]==0
        wrong=RuntimeContext(root;session_id="another",permissions=ctx.permissions,state_dir=ctx.state_dir)
        @test_throws ShenScopeError execute(tool,args,wrong)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"evidence","profile_job_id"=>inferred["job_id"]),ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"evidence"),ctx)
        @test_throws ShenScopeError execute(tool,merge(args,Dict("file"=>"src/Util.jl")),ctx)
        other=ShenScope.compiler_ir_report("digest_string")
        @test_throws ShenScopeError ShenScope.runtime_evidence_validate_reports(other,completed.result["report"],runtime_source_snapshot(ctx))
        stale=merge(args,Dict("expected_evidence_sha256"=>repeat("0",64)))
        @test_throws ShenScopeError execute(tool,stale,ctx)
        close_operations!(tool.operations)
    end
end

@testset "CLI and real agent diagnostics inspect combine actual fixed-Core execution evidence" begin
    mktempdir() do root
        state=joinpath(root,"state");config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread = \"allow\"\ndynamic = \"allow\"\nprocess = \"allow\"\n")
        entry="using ShenScope; exit(ShenScope.main(ARGS))"
        command=`$(Base.julia_cmd()) --startup-file=no --project=$(ShenScope.runtime_core_root()) -e $entry -- diagnostics inspect digest_string --iterations 1 --repetitions 1 --max-samples 4 --max-frames 1 --limit 4 --root $root --config $config --state-dir $state --timeout 120`
        result=parsejson(read(command,String))
        @test result["schema"]==ShenScope.RUNTIME_EVIDENCE_SCHEMA && length(result["report_stamps"])==2
        @test result["execution"]["separate_processes"]==2 && !result["execution"]["project_loading"]
        @test result["summary"]["observation_kinds"]["allocation"]>0 && result["summary"]["observation_kinds"]["statement"]>0
        tool=DiagnosticsTool();ctx=RuntimeContext(root;state_dir=state,permissions=PermissionPolicy(;rules=Dict(
            :read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow)))
        call=ToolCall("diagnostics",Dict("action"=>"inspect","target"=>"digest_string",
            "iterations"=>1,"repetitions"=>1,"max_samples"=>4,"max_frames"=>1,"limit"=>4,"timeout"=>120))
        provider=MockProvider([response(;calls=[call]),response("Inspected actual Core evidence.")])
        session=new_session(ctx)
        @test run_agent!(provider,"Inspect Core inference and actual allocation evidence.",ctx;session,tools=[tool])=="Inspected actual Core evidence."
        observed=only(parsejson(message.text) for message in session.messages if message.role==:tool)
        @test observed["ok"]
        data=observed["value"]
        @test data["schema"]==ShenScope.RUNTIME_EVIDENCE_SCHEMA && data["summary"]["observations"]>0
        @test !data["producer_authenticated"] && !data["summary"]["automatic_project_indexing"]
        close_operations!(tool.operations)
    end
end
