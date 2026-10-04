@testset "CLI history evidence uses validated limits and a real saved parser index" begin
    mktempdir() do root
        ids, _ = history_fixture_repository(root)
        ctx = history_fixture_context(root)
        backend = TreeSitterBackend()
        try
            build!(backend,ctx)
            common = ["--root",root,"--state-dir",ctx.state_dir,"--config",joinpath(root,"config.toml"),"--allow-process"]
            output_path = joinpath(root,"cli-result.txt")
            for action in ("git_cochange","risk")
                status = open(output_path,"w") do output
                    redirect_stdout(output) do
                        ShenScope.main(["project",action,"a.jl",common...,"--bulk-threshold","2","--history-limit","7","--limit","1"])
                    end
                end
                value = parsejson(read(output_path,String))
                @test status == 0 && value["analyzer"] == action && length(value["candidates"]) == 1
                @test value["coverage"]["head"] == last(ids) && value["coverage"]["commit_limit"] == 7
                @test first(value["candidates"])["file"] == (action == "git_cochange" ? "b.jl" : "a.jl")
            end
            @test ShenScope.main(["project","risk",common...,"--history-limit","513"]) == 1
            @test ShenScope.main(["project","risk",common...,"--minimum-support","0"]) == 1
            @test ShenScope.main(["project","git_cochange",common...]) == 1
        finally
            backend_close!(backend)
        end
    end
end
