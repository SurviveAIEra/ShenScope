using JSON3

@testset "Four real backends converge watched 1/5/20-file batches to complete rebuilds" begin
    trials=Dict{String,Any}[]
    for (name,make_backend,extension) in (("go_ast",GoASTBackend,"go"),("tree_sitter",TreeSitterBackend,"go"),
            ("codegraph",CodeGraphBackend,"go"),("typescript",TypeScriptSemanticBackend,"ts"))
        mktempdir() do root
            fixture(index,revision)=extension=="go" ? "package watched\nfunc F$index() int { return $revision }\nfunc TestF$index() int { return F$index() }\n" :
                "export function F$index(): number { return $revision; }\nexport function TestF$index(): number { return F$index(); }\n"
            for index in 1:21;write(joinpath(root,"f$index.$extension"),fixture(index,0));end
            ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:session)
            backend=make_backend();watch=nothing
            try
                state=build!(backend,ctx)
                watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,native_hints=false,poll_seconds=0.05,quiet_seconds=0.02))
                @test timedwait(()->project_watch_status(watch)["scans"]>0,15)==:ok
                for changed in (1,5,20)
                    count_before=watch.updates;revision=state.revision
                    for index in 1:changed;write(joinpath(root,"f$index.$extension"),fixture(index,changed));end
                    @test timedwait(()->project_watch_status(watch)["updates"]>count_before,30)==:ok
                    @test state.revision==revision+1
                    oracle_backend=make_backend();oracle_ctx=RuntimeContext(root;state_dir=joinpath(root,"oracle-$name-$changed"),approve=request->:session)
                    try
                        oracle=build!(oracle_backend,oracle_ctx)
                        @test graph_snapshot(state)==graph_snapshot(oracle)
                        @test Dict(path=>ShenScope.facts_dict(facts) for (path,facts) in state.files)==
                            Dict(path=>ShenScope.facts_dict(facts) for (path,facts) in oracle.files)
                        @test state.metadata==oracle.metadata
                        push!(trials,Dict("backend"=>name,"changed_files"=>changed,"watched_revision"=>state.revision,
                            "full_facts_oracle"=>"equal","watch_updates"=>watch.updates,"watch_scans"=>watch.scans))
                    finally;backend_close!(oracle_backend);end
                end
                graph=graph_snapshot(state);revision=state.revision;journal=read(state.journal.path);failed=watch.failed_updates
                write(joinpath(root,"f1.$extension"),extension=="go" ? "package watched\nfunc BROKEN( {" : "export function BROKEN( {\n")
                @test timedwait(()->project_watch_status(watch)["failed_updates"]>failed,15)==:ok
                @test graph_snapshot(state)==graph && state.revision==revision && read(state.journal.path)==journal
                scans=watch.scans;attempts=watch.failed_updates
                @test timedwait(()->project_watch_status(watch)["scans"]>=scans+3,5)==:ok
                @test watch.failed_updates==attempts
                write(joinpath(root,"f1.$extension"),fixture(1,99))
                @test timedwait(()->state.revision==revision+1,15)==:ok
                stop_project_watch!(watch)
                @test istaskdone(watch.task) && !iscancelled(ctx.cancellation)
                @test graph_snapshot(load_project(backend,ctx))==graph_snapshot(state)
            finally
                watch!==nothing && stop_project_watch!(watch)
                backend_close!(backend)
            end
        end
    end
    if haskey(ENV,"SHENSCOPE_WATCH_EVIDENCE")
        open(ENV["SHENSCOPE_WATCH_EVIDENCE"],"w") do output
            JSON3.pretty(output,JSON3.write(Dict("trials"=>trials,"fixture_files"=>21,
                "limits"=>["Small offline fixtures; no large-graph convergence latency or speed-advantage claim.",
                    "Recursive content scans are periodic; native root events are hints, not recursive coverage."])))
        end
    end
end

@testset "Actual TypeScript watcher follows inherited configuration and newly selected source scope" begin
    mktempdir() do root
        mkpath(joinpath(root,"config"));write(joinpath(root,"config","base.json"),"{\"compilerOptions\":{\"strict\":true}}")
        write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./config/base.json\",\"include\":[\"*.ts\"]}")
        write(joinpath(root,"main.ts"),"export const n: number = null;\n")
        mkpath(joinpath(root,"extras"));write(joinpath(root,"extras","helper.ts"),"export function Helper(): number { return 7; }\n")
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:session)
        backend=TypeScriptSemanticBackend();watch=nothing
        try
            state=build!(backend,ctx);@test any(d->d["category"]=="error",state.files["main.ts"].diagnostics)
            watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,native_hints=false,poll_seconds=0.05,quiet_seconds=0.02))
            @test timedwait(()->watch.scans>0,10)==:ok
            @test watch.phase==:watching && watch.updates==0 && isempty(watch.dirty)
            @test !haskey(state.files,"extras/helper.ts")
            revision=state.revision
            write(joinpath(root,"config","base.json"),"{\"compilerOptions\":{\"strict\":false}}")
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test isempty(state.files["main.ts"].diagnostics)
            revision=state.revision;fingerprint=project_fingerprint(state);bytes=read(state.journal.path)
            write(joinpath(root,"tsconfig.json"),"{ broken config")
            @test timedwait(()->watch.failed_updates>0,15)==:ok
            @test state.revision==revision && project_fingerprint(state)==fingerprint && read(state.journal.path)==bytes
            @test project_watch_status(watch)["configuration_error"]!==nothing
            write(joinpath(root,"config","other.json"),"{\"compilerOptions\":{\"strict\":true}}")
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./config/other.json\",\"include\":[\"*.ts\"]}")
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test any(d->d["category"]=="error",state.files["main.ts"].diagnostics)
            revision=state.revision
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./config/other.json\",\"include\":[\"**/*.ts\"]}")
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test haskey(state.files,"extras/helper.ts")
            revision=state.revision
            write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./config/other.json\",\"include\":[\"*.ts\"]}")
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test !haskey(state.files,"extras/helper.ts")
            stop_project_watch!(watch)
            watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,native_hints=false,poll_seconds=0.05,quiet_seconds=0.02))
            @test timedwait(()->watch.scans>0,10)==:ok
            @test watch.phase==:watching && watch.updates==0
            revision=state.revision
            rm(joinpath(root,"extras","helper.ts"))
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test !haskey(watch.applied.files,"extras/helper.ts")
            revision=state.revision
            rm(joinpath(root,"tsconfig.json"))
            @test timedwait(()->state.revision==revision+1,15)==:ok
            @test isempty(state.metadata["compiler"]["configuration_sources"])
            @test !haskey(ShenScope.scan_project_watch(watch).files,"config/other.json")
        finally
            watch!==nothing && stop_project_watch!(watch)
            backend_close!(backend)
        end
    end
end
