function migration_real_sources(root::String;typescript=false)
    sources = typescript ? Dict(
        "a.ts" => "export function A(): number { return 1; }\n",
        "b.ts" => "import { A } from './a'; import { C } from './c'; export function B(): number { return A() + C(); }\n",
        "c.ts" => "import { B } from './b'; export function C(): number { return B(); }\n",
        "d.ts" => "import { A } from './a'; export function D(): number { return A(); }\n",
        "t.test.ts" => "import { B } from './b'; export function TestCaller(): number { return B(); }\n") : Dict(
        "a.go" => "package fixture\nfunc A() int { return 1 }\n",
        "b.go" => "package fixture\nfunc B() int { return A() + C() }\n",
        "c.go" => "package fixture\nfunc C() int { return B() }\n",
        "d.go" => "package fixture\nfunc D() int { return A() }\n",
        "t_test.go" => "package fixture\nfunc TestCaller() int { return B() }\n")
    for (path,source) in sources;write(joinpath(root,path),source);end
    typescript && write(joinpath(root,"tsconfig.json"),"{\"compilerOptions\":{\"strict\":true,\"target\":\"ES2022\"},\"include\":[\"*.ts\"]}")
    sources
end

@testset "Migration proposal works across four actual project-data backends" begin
    for make_backend in (GoASTBackend,TreeSitterBackend,CodeGraphBackend,TypeScriptSemanticBackend)
        mktempdir() do root
            typescript=make_backend===TypeScriptSemanticBackend
            sources=migration_real_sources(root;typescript)
            ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Allow,:persistence=>Allow,:network=>Deny)))
            backend=make_backend()
            try
                state=build!(backend,ctx)
                @test length(state.files)==5
                extension=typescript ? ".ts" : ".go"
                seed="a"*extension
                proposal=analyze(MigrationAnalyzer(),state,Dict("paths"=>[seed]),ctx)
                @test proposal["cycle_groups"]==1 && proposal["total_steps"]==4 && !proposal["truncated"]
                @test only(first(proposal["steps"])["files"])["path"]==seed
                group=only(step for step in proposal["steps"] if step["atomic_group"])
                @test [file["path"] for file in group["files"]]==["b"*extension,"c"*extension]
                @test any(step -> any(symbol -> symbol["name"]=="TestCaller",step["test_candidates"]),proposal["steps"])
                @test proposal["coverage"]["backend"]==backend_capabilities(backend).name
                @test all(edge -> all(witness -> haskey(state.relations,witness["relation_id"]),edge["evidence"]),group["dependencies"])
                @test all(path -> read(joinpath(root,path),String)==sources[path],keys(sources))
                @test analyze(ArchitectureAnalyzer(),state,Dict(),ctx)["cycles"]==[["b"*extension,"c"*extension]]
                partial=analyze(MigrationAnalyzer(),state,Dict("paths"=>[seed],"max_depth"=>0),ctx)
                @test partial["truncated"] && partial["status"]=="partial_proposal"
                # A plan is tied to its source/index fingerprint, not to a client
                # checklist status. A body edit and index update retire that ID.
                write(joinpath(root,seed),replace(sources[seed],"return 1"=>"return 2"))
                update!(backend,state,[seed],ctx)
                refreshed=analyze(MigrationAnalyzer(),state,Dict("paths"=>[seed]),ctx)
                @test refreshed["plan_id"]!=proposal["plan_id"] && refreshed["revision"]==proposal["revision"]+1
            finally
                backend_close!(backend)
            end
        end
    end
end

@testset "Migration CLI and RPC consume the saved graph without executing processes" begin
    mktempdir() do root
        migration_real_sources(root)
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Allow,:persistence=>Allow)))
        backend=GoASTBackend()
        server=nothing
        try
            build!(backend,ctx)
            config=joinpath(root,"config.toml")
            write(config,"[permissions]\nread='allow'\nprocess='deny'\nnetwork='deny'\npersistence='deny'\n")
            output_path=joinpath(root,"cli-output.txt")
            status=open(output_path,"w") do output
                redirect_stdout(output) do
                    ShenScope.main(["project","migration","a.go","--backend","go_ast","--root",root,
                        "--state-dir",ctx.state_dir,"--config",config,"--order","callers_first"])
                end
            end
            value=parsejson(read(output_path,String))
            @test status==0 && value["order"]=="callers_first" && value["cycle_groups"]==1
            @test !value["writes_performed"] && !value["execution_registered"]
            server=CoreServer(root;state_dir=ctx.state_dir,config_file=config,output=IOBuffer())
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            session=dispatch_rpc(server,"sessions/create",Dict("title"=>"Migration review"))["id"]
            start=dispatch_rpc(server,"project/start",Dict("session_id"=>session,"action"=>"migration",
                "backend"=>"go_ast","paths"=>["a.go"]))
            @test timedwait(()->dispatch_rpc(server,"project/job",Dict("session_id"=>session,"job_id"=>start["job_id"]))["status"]!="running",60;pollint=0.01)==:ok
            job=dispatch_rpc(server,"project/job",Dict("session_id"=>session,"job_id"=>start["job_id"]))
            @test job["status"]=="complete" && job["result"]["cycle_groups"]==1
            @test isempty(server.approvals) && isempty(load_session(ctx.state_dir,session).messages)
            manager=ShenScope.server_project_tool(server).manager
            @test manager.backends["go_ast"].worker.process===nothing
            @test_throws RPCFault dispatch_rpc(server,"project/query",Dict("backend"=>"go_ast","action"=>"migration"))
        finally
            server!==nothing && stop_server!(server)
            backend_close!(backend)
        end
    end
end
