using JSON3

function graph_fixture(path,index;revision=0)
    write(path,"package fixture\nfunc F$index() int { return $revision }\nfunc TestF$index() int { return F$index() }\n")
end

@testset "Real parser backends share analyzers and 1/5/20-file rebuild oracles" begin
    records=Dict{String,Any}[]
    for make_backend in (GoASTBackend,TreeSitterBackend,CodeGraphBackend)
        mktempdir() do root
            ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once)
            paths=["f$i.go" for i in 1:21]
            for (i,path) in enumerate(paths);graph_fixture(joinpath(root,path),i);end
            backend=make_backend();name=backend_capabilities(backend).name
            try
                state=build!(backend,ctx)
                @test length(state.files)==21
                @test length(graph_search(state,"F1";kind=:function)["symbols"])>=1
                found=first([s for s in values(state.symbols) if s.name=="F1"])
                request=Dict("symbols"=>[found.id.value])
                impact=analyze(ImpactAnalyzer(),state,request,ctx)
                @test any(c->c["symbol"]["name"]=="TestF1",impact["candidates"])
                candidates=analyze(TestSelectionAnalyzer(),state,request,ctx)["candidates"]
                @test any(c->c["symbol"]["name"]=="TestF1",candidates)
                @test isempty(analyze(ArchitectureAnalyzer(),state,Dict(),ctx)["cycles"])
                @test graph_snapshot(load_project(backend,ctx))==graph_snapshot(state)
                @test update!(backend,state,["f1.go"],ctx).revision==state.revision
                for changed in (1,5,20)
                    for index in 1:changed;graph_fixture(joinpath(root,paths[index]),index;revision=changed);end
                    before=state.revision
                    stats=@timed update!(backend,state,paths[1:changed],ctx)
                    delta=stats.value
                    @test delta.revision==before+1
                    @test length(delta.changed_files)==changed
                    @test length(delta.relinked_files)==changed
                    oracle_ctx=RuntimeContext(root;state_dir=joinpath(root,"oracle-$name-$changed"),approve=r->:once)
                    oracle_backend=make_backend()
                    try
                        full=@timed build!(oracle_backend,oracle_ctx)
                        @test graph_snapshot(state)==graph_snapshot(full.value)
                        push!(records,Dict("backend"=>name,"changed_files"=>changed,"incremental_seconds"=>stats.time,
                            "incremental_bytes"=>stats.bytes,"full_seconds"=>full.time,"full_bytes"=>full.bytes,
                            "oracle"=>"equal","phases"=>delta.timings))
                    finally;backend_close!(oracle_backend);end
                end
                previous=graph_snapshot(state);version=state.revision;size=filesize(state.journal.path)
                write(joinpath(root,"f1.go"),"package fixture\nfunc BROKEN( {\n")
                @test_throws ShenScopeError update!(backend,state,["f1.go"],ctx)
                @test state.revision==version
                @test graph_snapshot(state)==previous
                @test filesize(state.journal.path)==size
                graph_fixture(joinpath(root,"f1.go"),1;revision=99)
                @test update!(backend,state,["f1.go"],ctx).revision==version+1
                rm(joinpath(root,"f21.go"))
                @test update!(backend,state,["f21.go"],ctx).removed_symbols>0
                @test !haskey(state.files,"f21.go")
                @test all(e->haskey(state.symbols,e.src) && haskey(state.symbols,e.dst),values(state.relations))
                reloaded=load_project(backend,ctx)
                @test graph_snapshot(reloaded)==graph_snapshot(state)
                # A complete journal frame without a transaction commit must be discarded.
                ShenScope.append_record!(state.journal,Dict("kind"=>"project_begin","revision"=>state.revision+1,"root"=>root,"backend"=>name))
                restored=load_project(backend,ctx)
                @test restored.revision==state.revision
                @test graph_snapshot(restored)==graph_snapshot(state)
                @test restored.journal_sequence==state.journal_sequence
                @test_throws ShenScopeError graph_traverse(state,[SymbolId(repeat("0",32))])
                @test_throws ShenScopeError update!(backend,state,["../escape.go"],ctx)
            finally;backend_close!(backend);end
        end
    end
    if haskey(ENV,"SHENSCOPE_GRAPH_EVIDENCE")
        open(ENV["SHENSCOPE_GRAPH_EVIDENCE"],"w") do io
            JSON3.pretty(io,JSON3.write(Dict("fixture_files"=>21,"trials"=>records,
                "limits"=>["Small offline fixtures; timings include first JIT where applicable.","CodeGraph SDK still performs global relinking/export; no competitive performance claim."])))
        end
    end
end

@testset "Syntax ambiguity, cross-file invalidation, cycles and scope" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once);backend=GoASTBackend()
        try
            write(joinpath(root,"a.go"),"package p\nfunc A() int { return B() }\n")
            write(joinpath(root,"b.go"),"package p\nfunc B() int { return A() }\n")
            state=build!(backend,ctx)
            @test analyze(ArchitectureAnalyzer(),state,Dict(),ctx)["cycles"]==[["a.go","b.go"]]
            write(joinpath(root,"b.go"),"package p\nfunc C() int { return A() }\n")
            delta=update!(backend,state,["b.go"],ctx)
            @test Set(delta.relinked_files)==Set(["a.go","b.go"])
            @test !any(e->state.symbols[e.dst].name=="B",values(state.relations))
            write(joinpath(root,"other.go"),"package p\nfunc C() int { return 0 }\n")
            update!(backend,state,["other.go"],ctx)
            write(joinpath(root,"a.go"),"package p\nfunc A() int { return C() }\n")
            update!(backend,state,["a.go"],ctx)
            @test !any(e->e.kind==:calls && state.symbols[e.src].name=="A",values(state.relations))
            @test ShenScope.project_status(state)["unresolved_syntax_calls"]>=1
            @test graph_search(state,"";limit=1)["next_offset"]==1
            @test length(graph_search(state,"";limit=1,offset=1)["symbols"])==1
            denied=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
            @test_throws ShenScopeError update!(backend,state,["a.go"],denied)
            @test_throws ShenScopeError graph_search(state,"x";limit=0)
        finally;backend_close!(backend);end
    end
end
