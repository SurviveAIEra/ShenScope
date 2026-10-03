using JSON3

@testset "Compiler 1/5/20-file deltas match full facts and preserve symbol identity" begin
    records=Dict{String,Any}[]
    mktempdir() do root
        fixture(index,revision=0)="export function F$index(): number { return $(index+revision); }\n"
        paths=["f$i.ts" for i in 1:21]
        for (index,path) in enumerate(paths);write(joinpath(root,path),fixture(index));end
        write(joinpath(root,"consumer.ts"),join(["import { F$i } from './f$i';" for i in 1:21],"\n")*
            "\nexport function TestAll(): number { return "*join(["F$i()" for i in 1:21]," + ")*"; }\n")
        ctx=semantic_context(root);backend=TypeScriptSemanticBackend()
        try
            state=build!(backend,ctx)
            @test length(state.files)==22
            original_ids=Set(keys(state.symbols));consumer_sha=state.files["consumer.ts"].sha256
            for changed in (1,5,20)
                for index in 1:changed;write(joinpath(root,paths[index]),fixture(index,changed));end
                before=state.revision;bytes=filesize(state.journal.path)
                incremental=@timed update!(backend,state,paths[1:changed],ctx)
                @test incremental.value.revision==before+1
                @test Set(incremental.value.changed_files)==Set(paths[1:changed])
                @test Set(keys(state.symbols))==original_ids
                @test state.files["consumer.ts"].sha256==consumer_sha
                oracle_context=semantic_context(root,"oracle-$changed");oracle_backend=TypeScriptSemanticBackend()
                try
                    full=@timed build!(oracle_backend,oracle_context)
                    @test semantic_snapshot(full.value)==semantic_snapshot(state)
                    @test graph_snapshot(full.value)==graph_snapshot(state)
                    @test full.value.metadata==state.metadata
                    push!(records,Dict("backend"=>"typescript","changed_files"=>changed,"oracle"=>"equal",
                        "incremental_seconds"=>incremental.time,"full_seconds"=>full.time,
                        "incremental_bytes"=>incremental.bytes,"full_bytes"=>full.bytes,
                        "persisted_bytes"=>filesize(state.journal.path)-bytes,"phases"=>incremental.value.timings))
                finally;backend_close!(oracle_backend);end
            end
            # A public signature change must recheck the unchanged dependent file.
            write(joinpath(root,"f1.ts"),"export function F1(): string { return 'changed'; }\n")
            delta=update!(backend,state,["f1.ts"],ctx)
            @test "consumer.ts" in delta.changed_files
            @test state.files["consumer.ts"].sha256==consumer_sha
            @test !isempty(state.files["consumer.ts"].diagnostics)
            @test Set(keys(state.symbols))==original_ids
            previous=semantic_snapshot(state);version=state.revision;bytes=filesize(state.journal.path)
            write(joinpath(root,"f1.ts"),"export function Broken( {\n")
            @test semantic_error_code(()->update!(backend,state,["f1.ts"],ctx))==:parse
            @test state.revision==version && filesize(state.journal.path)==bytes
            @test semantic_snapshot(state)==previous
            @test backend.worker.process!==nothing && !process_exited(backend.worker.process)
            write(joinpath(root,"f1.ts"),fixture(1,100))
            @test update!(backend,state,["f1.ts"],ctx).revision==version+1
            rm(joinpath(root,"f21.ts"))
            @test update!(backend,state,["f21.ts"],ctx).removed_symbols>0
            @test !haskey(state.files,"f21.ts")
            @test all(edge->haskey(state.symbols,edge.src) && haskey(state.symbols,edge.dst),values(state.relations))
            @test semantic_snapshot(load_project(backend,ctx))==semantic_snapshot(state)
            # Excludes affect roots, but imports can still bring an excluded file into the program.
            write(joinpath(root,"tsconfig.json"),"{\"files\": [\"consumer.ts\"], \"exclude\": [\"f*.ts\"]}")
            update!(backend,state,["tsconfig.json"],ctx)
            @test state.metadata["compiler"]["root_count"]==1
            @test length(state.files)==21
            @test state.files["consumer.ts"].metadata["root"]
            @test !state.files["f1.ts"].metadata["root"]
            write(joinpath(root,"tsconfig.json"),"{\"files\": [\"f1.ts\"]}")
            @test "consumer.ts" in update!(backend,state,["tsconfig.json"],ctx).changed_files
            @test Set(keys(state.files))==Set(["f1.ts"])
            @test semantic_snapshot(load_project(backend,ctx))==semantic_snapshot(state)
            write(joinpath(root,"tsconfig.json"),"{\"files\": []}")
            update!(backend,state,["tsconfig.json"],ctx)
            @test isempty(state.files) && isempty(state.symbols) && isempty(state.relations)
        finally;backend_close!(backend);end
    end
    if haskey(ENV,"SHENSCOPE_SEMANTIC_EVIDENCE")
        write(ENV["SHENSCOPE_SEMANTIC_EVIDENCE"],JSON3.write(Dict("fixture_files"=>22,"trials"=>records,
            "limits"=>["Small offline fixtures; first JIT is included where applicable.",
                "Resident compiler caches source ASTs, but semantic facts are recomputed globally; no speed advantage is claimed."])))
    end
end
