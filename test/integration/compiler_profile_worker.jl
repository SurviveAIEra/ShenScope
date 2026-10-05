@testset "Real runtime profile helper shares permissions, source checks and termination" begin
    mktempdir() do root
        approvals=Symbol[]
        ctx=RuntimeContext(root;approve=request->(push!(approvals,request.category);:once))
        result=ShenScope.run_profile_diagnostic(ctx,"cliptext_string";timeout=120,iterations=2,repetitions=2,max_samples=16,max_frames=2)
        @test approvals==[:dynamic,:process]
        @test result["report"]["schema"]==ShenScope.COMPILER_PROFILE_SCHEMA
        @test result["report"]["runtime"]["threads"]==1
        @test result["execution"]["separate_process"] && !result["execution"]["os_sandbox"]
        @test result["report"]["output_consistent_across_passes"]
        @test result["report"]["allocation_summary"]["samples_truncated"]
        @test all(row->row["allocated_bytes"]>0,result["report"]["timings"])
        for category in (:read,:dynamic,:process)
            rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow);rules[category]=Deny
            @test_throws ShenScopeError ShenScope.run_profile_diagnostic(RuntimeContext(root;permissions=PermissionPolicy(;rules)),"digest_string")
        end
        restricted=RuntimeContext(root;sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy()))
        @test_throws ShenScopeError ShenScope.run_profile_diagnostic(restricted,"digest_string")
        @test_throws ShenScopeError ShenScope.run_profile_diagnostic(ctx,"remove_graph_edge")
        @test_throws ShenScopeError ShenScope.run_profile_diagnostic(ctx,"digest_string";timeout=true)
        reference=Ref{RuntimeContext}()
        revoked=RuntimeContext(root;approve=request->begin
            request.category==:process && (reference[].permissions.rules[:dynamic]=Deny)
            :once
        end)
        reference[]=revoked
        @test_throws ShenScopeError ShenScope.run_profile_diagnostic(revoked,"digest_string";timeout=120)
        @test_throws ShenScopeError ShenScope.run_profile_diagnostic(ctx,"digest_string";timeout=0.1)
    end
end

@testset "Agent and CLI execute fixed profile workloads through the same Core action" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(
            :read=>Allow,:dynamic=>Allow,:process=>Allow,:network=>Deny,:edit=>Deny,:persistence=>Allow)))
        session=new_session(ctx);tool=DiagnosticsTool()
        arguments=Dict("action"=>"profile","target"=>"digest_string","iterations"=>1,"repetitions"=>1,
            "max_samples"=>4,"max_frames"=>1,"timeout"=>120)
        provider=MockProvider([response(;calls=[ToolCall("diagnostics",arguments)]),response("Measured fixture evidence.")])
        @test run_agent!(provider,"Measure the fixed digest fixture",ctx;session,tools=[tool])=="Measured fixture evidence."
        result=only(parsejson(message.text) for message in session.messages if message.role==:tool)
        @test result["ok"] && result["value"]["report"]["runtime_execution_observed"]
        @test result["value"]["execution"]["separate_process"]
        @test length(provider.requests)==2 && session.status==:complete
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\ndynamic='allow'\nprocess='allow'\nnetwork='deny'\npersistence='deny'\n")
        output=joinpath(root,"cli-profile.json")
        status=open(output,"w") do io
            redirect_stdout(io) do
                ShenScope.main(["diagnostics","profile","canonical_dictionary","--iterations","1","--repetitions","1",
                    "--max-samples","4","--max-frames","1","--sample-rate","1","--timeout","120","--root",root,"--config",config])
            end
        end
        @test status==0
        cli=parsejson(read(output,String))
        @test cli["report"]["fixture"]["name"]=="nested_dictionary" && cli["report"]["limits"]["max_samples"]==4
        @test cli["report"]["warmup"]["output"]==cli["report"]["sample_output"]
    end
end
