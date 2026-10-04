@testset "One isolated analyzer across four real project backends" begin
    mktempdir() do root
        write(joinpath(root,"sample.go"),"package fixture\nfunc target(value int) int { return value + 1 }\nfunc caller() int { return target(1) }\n")
        write(joinpath(root,"sample.py"),"def target(value):\n    return value + 1\ndef caller():\n    return target(1)\n")
        write(joinpath(root,"sample.ts"),"export function target(value: number): number { return value + 1; }\nexport function caller(): number { return target(1); }\n")
        for backend in (GoASTBackend(),TreeSitterBackend(),CodeGraphBackend(),TypeScriptSemanticBackend())
            ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow)))
            manager = AnalyzerManager()
            definition = AnalyzerDefinition("incoming",INCOMING_ANALYZER_SOURCE;tests=incoming_analyzer_tests())
            register_analyzer!(manager,definition,ctx)
            try
                state = build!(backend,ctx)
                before = project_fingerprint(state)
                result = analyze(IsolatedJuliaAnalyzer(manager,"incoming"),state,Dict(),ctx)
                @test result["backend"] == backend_capabilities(backend).name
                @test result["revision"] == state.revision
                @test result["fingerprint"] == before == project_fingerprint(state)
                @test result["validation"]["external_tests"]["count"] == 2
                @test !isempty(result["candidates"])
                incoming_targets = Set(edge.dst.value for edge in values(state.relations))
                @test Set(candidate["symbol"]["id"] for candidate in result["candidates"]) == incoming_targets
                for candidate in result["candidates"]
                    id = SymbolId(candidate["symbol"]["id"])
                    recorded = [edge for edge in values(state.relations) if edge.dst == id]
                    @test length(candidate["evidence"]) == length(recorded)
                    @test Set(candidate["evidence"]) == Set(edge.id for edge in recorded)
                    @test candidate["confidence"] == minimum(edge.confidence for edge in recorded)
                    @test candidate["score"] == length(recorded)/length(state.relations)
                    @test candidate["symbol"] == ShenScope.symbol_dict(state.symbols[id])
                end
                @test isempty(manager.processes.handles) && isempty(ctx.budget.reservations)
            finally
                backend_close!(backend);cleanup_analyzers!(manager)
            end
        end
    end
end
