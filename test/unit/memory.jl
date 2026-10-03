@testset "Scoped memory, lexical retrieval and durable versions" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once)
        store=memory_store(ctx)
        entry=memory_put!(store,"julia","Julia 中文代码图检索",ctx;expected_version=0,title="代码图",tags=["analysis"])
        @test entry["version"]==1
        @test memory_get(memory_store(ctx),"julia",ctx)["value"]["content_sha256"]==digest("Julia 中文代码图检索")
        @test_throws ShenScopeError memory_put!(store,"julia","stale",ctx;expected_version=0)
        memory_put!(store,"python","Python unittest fixtures",ctx;expected_version=0)
        @test first(memory_search(store,"代码图",ctx))["key"]=="julia"
        @test first(memory_search(store,"PYTHON",ctx))["key"]=="python"
        @test isempty(memory_search(store,"unrelated",ctx))
        @test "中文" in lexical_tokens("中文 Julia")
        for version in 1:12
            memory_put!(store,"julia","value $version",ctx;expected_version=version)
        end
        @test length(version_history(store.versions,"julia";limit=100))==8
        @test first(version_history(store.versions,"julia"))["version"]==13
        expiry=time()+60
        memory_put!(store,"temporary","ephemeral",ctx;expected_version=0,expires=expiry)
        @test isempty(memory_search(store,"ephemeral",ctx;at=expiry+1))
        memory_delete!(store,"python",ctx;expected_version=1)
        @test memory_get(store,"python",ctx)===nothing
        @test version_get(store.versions,"python";include_deleted=true)["version"]==2
        @test_throws ShenScopeError memory_put!(store,"bad","value",ctx;expected_version=0,expires=Inf)
        child=child_context(ctx;session_id=string(Base.UUID(1)))
        session_store=memory_store(ctx,:session)
        @test_throws ShenScopeError memory_get(session_store,"julia",child)
        mktempdir() do another
            other=RuntimeContext(another;state_dir=ctx.state_dir,approve=r->:once)
            @test memory_get(memory_store(other),"julia",other)===nothing
            @test_throws ShenScopeError memory_get(store,"julia",other)
            memory_put!(memory_store(ctx,:user),"user","shared local preference",ctx;expected_version=0)
            @test memory_get(memory_store(other,:user),"user",other)!==nothing
            exported=memory_export(store,ctx)
            @test length(memory_import!(memory_store(other),exported,other))==2
            @test memory_get(memory_store(other),"julia",other)["value"]["source"]=="import"
            @test_throws ShenScopeError memory_import!(memory_store(other),exported,other)
        end
        denied=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:persistence=>Deny)))
        @test_throws ShenScopeError memory_put!(memory_store(denied),"denied","no",denied;expected_version=0)
        @test version_get(store.versions,"denied")===nothing
        results=fetch.([Threads.@spawn(try memory_put!(store,"race","$i",ctx;expected_version=0) catch e;e end) for i in 1:8])
        @test count(r->r isa AbstractDict,results)==1
        @test all(r->r isa AbstractDict || r isa ShenScopeError,results)
        @test execute(MemoryTool(),Dict("action"=>"get","key"=>"race"),ctx)["version"]==1
    end
end

@testset "Memory import validates every item before atomic commit" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once);store=memory_store(ctx)
        value=Dict("content"=>"valid","content_sha256"=>digest("valid"),"title"=>"valid","tags"=>String[])
        malformed=deepcopy(value);malformed["tags"]=[repeat("x",129)]
        document=Dict("schema"=>1,"entries"=>[Dict("key"=>"first","value"=>value),Dict("key"=>"second","value"=>malformed)])
        @test_throws ShenScopeError memory_import!(store,document,ctx)
        @test isempty(version_list(store.versions))
        document["entries"][2]["value"]=value;document["entries"][2]["key"]="first"
        @test_throws ShenScopeError memory_import!(store,document,ctx)
        @test isempty(version_list(store.versions))
        bad=deepcopy(value);bad["content"]="tampered"
        @test_throws ShenScopeError memory_import!(store,Dict("schema"=>1,"entries"=>[Dict("key"=>"bad","value"=>bad)]),ctx)
        bounded=VersionedStore(joinpath(root,"bounded.jsonl");max_entries=1)
        version_put!(bounded,"one",Dict("v"=>1);expected_version=0)
        @test_throws ShenScopeError version_put!(bounded,"two",Dict("v"=>2);expected_version=0)
        @test length(version_list(bounded))==1
    end
end
