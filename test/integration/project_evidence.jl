@testset "Actual Go AST and Tree-sitter facts combine without launching helpers during reads" begin
    mktempdir() do root
        write(joinpath(root,"api.go"),"package p\nfunc Api() int { return 1 }\n")
        write(joinpath(root,"api_test.go"),"package p\nfunc TestApi() int { return Api() }\n")
        buildctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow,:process=>Allow)))
        go=GoASTBackend();tree=TreeSitterBackend()
        try
            build!(go,buildctx);build!(tree,buildctx)
        finally
            backend_close!(go);backend_close!(tree)
        end
        ctx=RuntimeContext(root;state_dir=buildctx.state_dir,
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Deny,:process=>Deny,:network=>Deny)))
        tool=ProjectTool();args=Dict{String,Any}("action"=>"evidence_compare","backends"=>["go_ast","tree_sitter"])
        result=execute(tool,args,ctx)
        @test result["total"]==2 && result["summary"]["eligible_bridges"]==2
        @test result["summary"]["symbols"]==8 && result["summary"]["files"]==2
        @test all(source->source["revision"]==1,result["sources"])
        @test all(backend->backend.worker.process===nothing,values(tool.manager.backends))
        status=execute(tool,Dict("action"=>"evidence_status"),ctx)
        @test count(source->source["indexed"],status["sources"])==2
        @test !status["automatic_indexing"]
        impact=execute(tool,merge(args,Dict("action"=>"evidence_impact","paths"=>["api.go"])),ctx)
        @test Set(item["observation"]["backend"] for item in impact["items"] if item["observation"]["symbol"]["name"]=="TestApi")==Set(["go_ast","tree_sitter"])
        tests=execute(tool,merge(args,Dict("action"=>"evidence_tests","paths"=>["api.go"])),ctx)
        @test tests["total"]==2 && all(item->!item["runtime_coverage_confirmed"],tests["items"])
        @test evidence_error_code(()->execute(tool,merge(args,Dict("expected_evidence_fingerprint"=>repeat("0",64))),ctx))==:conflict
        @test evidence_error_code(()->execute(tool,merge(args,Dict("backends"=>["go_ast","typescript"])),ctx))==:evidence_index
        write(joinpath(root,"api.go"),"package p\nfunc Api() int { return 2 }\n")
        @test evidence_error_code(()->execute(tool,args,ctx))==:stale_index
        ShenScope.cleanup_projects!(tool.manager)
    end
end

@testset "Actual CLI combines saved sources using read-only permissions" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        persist=RuntimeContext(root;state_dir=fixture.ctx.state_dir,
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow)))
        for state in fixture.states
            changes=Dict{String,Union{Nothing,FileFacts}}(path=>facts for (path,facts) in state.files)
            state.revision=0
            ShenScope.persist_delta!(state,changes)
        end
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\npersistence='deny'\nprocess='deny'\nnetwork='deny'\n")
        code=ShenScope.main(["project","evidence_compare","--root",root,"--state-dir",persist.state_dir,
            "--config",config,"--backends","go_ast,tree_sitter","--json"])
        @test code==0
    end
end
