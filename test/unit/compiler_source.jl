@testset "Actual Julia source coordinates are retained independently of display defaults" begin
    report=ShenScope.compiler_ir_report("cliptext_string")
    method=only(report["methods"])
    target=ShenScope.compiler_target("cliptext_string")
    code=only(Base.code_typed(target.callable,target.arguments;optimize=false,debuginfo=:source)).first
    expected=[ShenScope.compiler_ir_location(code,index,ShenScope.runtime_core_root()) for index in eachindex(code.code)]
    @test getindex.(method["statements"],"source")==expected
    counts=ShenScope.compiler_source_positions(method)
    @test counts["core"]>40 && counts["unknown"]>0
    @test sum(counts[key] for key in ("core","external","unknown"))==length(method["statements"])
    @test !counts["runtime_execution_observed"]
    ctx=RuntimeContext(ShenScope.runtime_core_root();permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    snapshot=runtime_source_snapshot(ctx)
    first=findfirst(row->row["source"]["scope"]=="core",method["statements"])
    preview=ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=first)
    @test preview["file"]==method["statements"][first]["source"]["file"]
    @test preview["focus_line"]==method["statements"][first]["source"]["line"]
    @test preview["source_sha256"]==digest(read(joinpath(snapshot.root,preview["file"]),String))
    @test only(row for row in preview["lines"] if row["focus"])["line"]==preview["focus_line"]
    @test !preview["producer_authenticated"] && preview["file_currentness"]=="bytes_match_recorded_hash"
    @test !occursin(snapshot.root,canonical(preview))
    declaration=ShenScope.compiler_source_excerpt(report,snapshot,ctx;context_lines=0)
    @test length(declaration["lines"])==1 && declaration["focus_line"]==method["identity"]["line"]
    @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;context_lines=21)
    @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;method_index=true)
    @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=4096)
    external=Dict("source"=>Dict("file"=>"same.jl","line"=>12,"scope"=>"external"),"opcode"=>"call","kind"=>"Expr")
    @test ShenScope.compiler_archive_statement_anchor(external)===nothing
    external["source"]=Dict("file"=>"src/a.jl","line"=>0,"scope"=>"core")
    @test ShenScope.compiler_archive_statement_anchor(external)===nothing
    @test ShenScope.compiler_archive_statement_anchor(method["statements"][first])!==nothing
end

@testset "Compiler preview bounds Unicode text and refuses stale, external and symlink source" begin
    mktempdir() do root
        mkpath(joinpath(root,"src"))
        path=joinpath(root,"src","preview.jl");text="# 中文🙂\r\n"*repeat("界🙂",500)*"\r\n# <script>literal</script>\r\n"
        write(path,text);hash=digest(text);fingerprint=repeat("b",64)
        snapshot=ShenScope.RuntimeSourceSnapshot(root,"ShenScope",Base.PkgId(ShenScope).uuid,v"0.1.0",
            [ShenScope.RuntimeSourceFile("src/preview.jl",ncodeunits(text),hash)],fingerprint)
        source=Dict("file"=>"src/preview.jl","line"=>2,"scope"=>"core")
        report=Dict("report_sha256"=>repeat("a",64),"source"=>Dict("fingerprint"=>fingerprint),
            "methods"=>[Dict("identity"=>Dict("file"=>"src/preview.jl","line"=>2),
                "statements"=>[Dict("source"=>deepcopy(source)),Dict("source"=>Dict("file"=>nothing,"line"=>nothing,"scope"=>"unknown"))])])
        ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Deny,:dynamic=>Deny)))
        result=ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=1,root)
        @test result["total_lines"]==4 && length(result["lines"])==4
        @test result["lines"][1]["text"]=="# 中文🙂"
        @test result["truncated_lines"]==1 && result["lines"][2]["truncated"]
        @test isvalid(result["lines"][2]["text"]) && ncodeunits(result["lines"][2]["text"])<=1024
        @test result["lines"][3]["text"]=="# <script>literal</script>"
        @test ncodeunits(canonical(result))<ShenScope.COMPILER_SOURCE_PREVIEW_BYTES
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=2,root)
        report["methods"][1]["statements"][1]["source"]["scope"]="external"
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=1,root)
        report["methods"][1]["statements"][1]["source"]=deepcopy(source)
        report["methods"][1]["statements"][1]["source"]["file"]="../preview.jl"
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=1,root)
        report["methods"][1]["statements"][1]["source"]=deepcopy(source)
        report["methods"][1]["statements"][1]["source"]["line"]=999
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;statement_id=1,root)
        write(path,text*"# changed\n")
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;root)
        write(path,text)
        denied=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,denied;root)
        cancelled=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
        cancel!(cancelled.cancellation)
        @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,cancelled;root)
        if Sys.isunix()
            alternate=joinpath(root,"alternate.jl");write(alternate,text);rm(path);symlink(alternate,path)
            @test_throws ShenScopeError ShenScope.compiler_source_excerpt(report,snapshot,ctx;root)
        end
    end
end

@testset "Owned compiler source RPC and archived file verification preserve boundaries" begin
    mktempdir() do root
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\ndynamic='deny'\nprocess='deny'\npersistence='allow'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            hello=dispatch_rpc(server,"initialize",Dict())
            @test hello["capabilities"]["compiler_source_preview"]
            owner=dispatch_rpc(server,"sessions/create",Dict("title"=>"Source owner"))["id"]
            other=dispatch_rpc(server,"sessions/create",Dict("title"=>"Source foreign"))["id"]
            ctx=ShenScope.server_context(server,owner);tool=ShenScope.server_diagnostics_tool(server)
            report=ShenScope.compiler_ir_report("cliptext_string")
            # Only this owned-retention fixture is admitted directly; real
            # isolated compiler child/RPC validation is covered by integration.
            started=ShenScope.start_operation!(tool.operations,ctx;kind="compile",metadata=Dict("mode"=>"graph")) do _
                Dict("report"=>report)
            end
            job=await_owned_operation(tool.operations,started["job_id"])
            @test job.status==:complete
            query=Dict("session_id"=>owner,"action"=>"compiler_source","job_id"=>started["job_id"],"statement_id"=>1)
            preview=dispatch_rpc(server,"diagnostics/query",query)
            @test preview["report_sha256"]==report["report_sha256"] && preview["statement_id"]==1
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/query",merge(query,Dict("session_id"=>other)))
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/query",merge(query,Dict("target"=>"digest_string")))
            fixture=compiler_archive_recorded_fixture();store=compiler_archive_store(ctx)
            id=compiler_archive_install_fixture!(store,ctx,fixture.result,fixture.source)
            archived=dispatch_rpc(server,"diagnostics/query",Dict("session_id"=>owner,"action"=>"archive_source","report_id"=>id))
            @test archived["recorded_report"] && archived["inventory_currentness"]=="not_checked"
            @test archived["source_sha256"]==report["methods"][1]["identity"]["source_sha256"]
            @test !archived["producer_authenticated"]
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/query",Dict("session_id"=>owner,
                "action"=>"archive_source","report_id"=>id,"expected_index_sha256"=>repeat("0",64)))
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/query",Dict("session_id"=>owner,
                "action"=>"archive_source","report_id"=>id,"statement_id"=>1))
            reading=RuntimeContext(root;session_id=owner,state_dir=ctx.state_dir,
                permissions=PermissionPolicy(;rules=Dict(:read=>Ask)),approve=request->:deny)
            @test_throws ShenScopeError execute(tool,Dict("action"=>"compiler_source","job_id"=>started["job_id"]),reading)
            approvals=String[]
            reading.approve=request->(push!(approvals,request.tool);:once)
            approved=execute(tool,Dict("action"=>"archive_source","report_id"=>id),reading)
            @test approved["file_currentness"]=="bytes_match_recorded_hash"
            @test approvals==["compiler.archive","runtime.diagnostics"]
        finally
            server.stopping || stop_server!(server)
        end
    end
end
