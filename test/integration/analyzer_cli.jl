@testset "Stateless analyzer CLI preserves archives and revalidates project runs" begin
    mktempdir() do root
        state = joinpath(root,"state")
        write(joinpath(root,"sample.go"),"package fixture\nfunc target() int { return 1 }\nfunc caller() int { return target() }\n")
        definition = AnalyzerDefinition("incoming",INCOMING_ANALYZER_SOURCE;tests=incoming_analyzer_tests())
        write(joinpath(root,"definition.json"),canonical(Dict("name"=>definition.name,"source"=>definition.source,
            "tests"=>ShenScope.analyzer_test_dict.(definition.tests))))
        common = ["--root",root,"--state-dir",state,"--allow-dynamic","--allow-persistence"]
        @test ShenScope.main(["analyzers","archive","definition.json",common...]) == 0
        @test ShenScope.main(["analyzers","versions","incoming",common...]) == 0
        @test ShenScope.main(["analyzers","inspect","incoming",definition.version,common...]) == 0
        @test ShenScope.main(["analyzers","restore","incoming",definition.version,common...]) == 0
        @test ShenScope.main(["analyzers","promote","definition.json",common...]) == 1
        @test ShenScope.main(["analyzers","versions",common...,"--offset","-1"]) == 1
        @test ShenScope.main(["analyzers","versions",common...,"--scope","workspace"]) == 1
        @test ShenScope.main(["analyzers","versions",common...,"--limit","101"]) == 1
        if ShenScope.compute_seccomp_available()
            @test ShenScope.main(["analyzers","promote","definition.json",common...,"--allow-process","--expected-pointer","0"]) == 0
            @test ShenScope.main(["project","build",common...,"--allow-process","--backend","go_ast"]) == 0
            @test ShenScope.main(["analyzers","run-archive","incoming",definition.version,common...,"--allow-process","--backend","go_ast"]) == 0
            @test ShenScope.main(["analyzers","run","definition.json",common...,"--allow-process","--backend","go_ast"]) == 0
            @test ShenScope.main(["analyzers","rollback","incoming",definition.version,common...,"--allow-process","--expected-pointer","1"]) == 0
            ctx = RuntimeContext(root;state_dir=state)
            @test first(analyzer_archive_history(ctx,"incoming")["history"])["pointer_revision"] == 2
        end
        @test ShenScope.main(["analyzers","history","incoming",common...]) == 0
        @test ShenScope.main(["analyzers","status",common...]) == 0
    end
end
