@testset "CLI archives actual inference in an existing conversation and restores it in a fresh invocation" begin
    mktempdir() do root
        ctx=compiler_archive_context(root);session=new_session(ctx)
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\ndynamic='allow'\nprocess='allow'\npersistence='allow'\nnetwork='deny'\n")
        common=["--root",root,"--state-dir",ctx.state_dir,"--config",config,"--session",session.id]
        function invoke(args)
            output=joinpath(root,"cli-output.json")
            status=open(output,"w") do io
                redirect_stdout(io) do;ShenScope.main(vcat(args,common));end
            end
            (status=status,result=status==0 ? parsejson(read(output,String)) : nothing)
        end
        saved=invoke(["diagnostics","compile","digest_string","--save","--mode","graph","--expected-revision","0","--title","CLI persisted report"])
        @test saved.status==0 && saved.result["archive"]["saved"]
        id=saved.result["report"]["report_sha256"]
        listed=invoke(["diagnostics","archive_list"])
        @test listed.status==0 && listed.result["total"]==1
        opened=invoke(["diagnostics","archive_get",id])
        @test opened.status==0 && opened.result["report"]==saved.result["report"]
        @test opened.result["source_currentness"]=="not_checked"
        labelled=invoke(["diagnostics","archive_label",id,"--title","CLI renamed","--expected-revision","1"])
        @test labelled.status==0 && labelled.result["revision"]==2
        @test invoke(["diagnostics","archive_delete",id,"--expected-revision","1"]).status==1
        @test invoke(["diagnostics","archive_save"]).status==1
        @test ShenScope.main(["diagnostics","archive_list","--root",root,"--state-dir",ctx.state_dir,"--config",config])==1
        @test invoke(["diagnostics","archive_delete",id,"--expected-revision","2"]).status==0
        planned=invoke(["diagnostics","archive_gc"])
        @test planned.status==0 && planned.result["dry_run"] && length(planned.result["items"])==1
        applied=invoke(["diagnostics","archive_gc","--apply-cleanup","--expected-revision","3"])
        @test applied.status==0 && applied.result["removed_assets"]==1
    end
end
