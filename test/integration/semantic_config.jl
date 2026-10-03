@testset "Inherited compiler aliases resolve against effective baseUrl or declaring config" begin
    mktempdir() do root
        for name in ("configs","old","mapped");mkpath(joinpath(root,name));end
        write(joinpath(root,"old","math.ts"),"export function calculate(): string { return 'old'; }\n")
        write(joinpath(root,"mapped","math.ts"),"export function calculate(): number { return 42; }\n")
        write(joinpath(root,"entry.ts"),"import { calculate } from '@math';\nexport function TestMapped(): number { return calculate(); }\n")
        ctx=semantic_context(root);backend=TypeScriptSemanticBackend()
        try
            # A child alias uses the inherited effective baseUrl, not its own directory.
            write(joinpath(root,"configs","base.json"),"{\"compilerOptions\":{\"baseUrl\":\"../mapped\"}}")
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./configs/base.json\",\"compilerOptions\":{\"paths\":{\"@math\":[\"math\"]}},\"files\":[\"entry.ts\"]}")
            state=build!(backend,ctx)
            function target()
                caller=only(s for s in values(state.symbols) if s.name=="TestMapped")
                only(state.symbols[e.dst].location.file for e in values(state.relations) if e.kind==:calls && e.src==caller.id)
            end
            @test target()=="mapped/math.ts"
            @test isempty(state.files["entry.ts"].diagnostics)
            @test state.metadata["compiler"]["options"]["paths"]["@math"]==[joinpath(root,"mapped","math")]
            # A child baseUrl overrides the inherited aliases' resolution base.
            write(joinpath(root,"configs","base.json"),"{\"compilerOptions\":{\"baseUrl\":\"../old\",\"paths\":{\"@math\":[\"math\"]}}}")
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./configs/base.json\",\"compilerOptions\":{\"baseUrl\":\"./mapped\"},\"files\":[\"entry.ts\"]}")
            update!(backend,state,["tsconfig.json"],ctx)
            @test target()=="mapped/math.ts"
            @test isempty(state.files["entry.ts"].diagnostics)
            # Without baseUrl, the inherited paths retain their declaration directory.
            write(joinpath(root,"configs","base.json"),"{\"compilerOptions\":{\"paths\":{\"@math\":[\"../mapped/math\"]}}}")
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./configs/base.json\",\"files\":[\"entry.ts\"]}")
            update!(backend,state,["tsconfig.json"],ctx)
            @test target()=="mapped/math.ts"
            @test isempty(state.files["entry.ts"].diagnostics)
            @test !haskey(state.metadata["compiler"]["options"],"pathsBasePath")
            @test semantic_snapshot(load_project(backend,ctx))==semantic_snapshot(state)
        finally;backend_close!(backend);end
    end
end
