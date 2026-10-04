@testset "Foreground project watch CLI emits actual owned lifecycle and closes at duration" begin
    mktempdir() do root
        write(joinpath(root,"main.go"),"package watched\nfunc F() int { return 0 }\n")
        config=joinpath(root,"config.toml");write(config,"")
        output=joinpath(root,"events.txt")
        code=open(output,"w") do stream
            redirect_stdout(stream) do
                ShenScope.main(["project","watch","--backend","go_ast","--root",root,"--state-dir",joinpath(root,"state"),
                    "--config",config,"--allow-process","--allow-persistence","--no-native-hints","--duration","0.3",
                    "--poll-seconds","0.05","--quiet-seconds","0.02","--json"])
            end
        end
        @test code==0
        events=ShenScope.parsejson.(split(strip(read(output,String)),'\n'))
        @test any(e->e["kind"]=="project_watch_started",events)
        @test any(e->e["kind"]=="project_watch_stopped" && e["payload"]["phase"]=="stopped",events)
        @test !any(e->startswith(e["kind"],"model_"),events)
        @test all(e->e["session_id"]=="cli-project-watch",events)
        @test_throws ShenScopeError ShenScope.cli_project_watch(["project","watch"],Dict("--duration"=>"NaN"),ShenScope.load_config(;path=config),joinpath(root,"state"))
        @test_throws ShenScopeError ShenScope.cli_project_watch(["project","watch","extra"],Dict(),ShenScope.load_config(;path=config),joinpath(root,"state"))
    end
end
