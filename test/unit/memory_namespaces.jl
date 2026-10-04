@testset "Independent memory namespaces, capacity and workspace ownership" begin
    mktempdir() do root
        ctx=memory_fixture_context(root)
        plain=memory_store(ctx);notes=memory_store(ctx;namespace="notes");tasks=memory_store(ctx;namespace="tasks")
        @test plain.versions.journal.path==joinpath(ctx.state_dir,"memory","workspace",digest(ctx.root)*".jsonl")
        @test plain.versions.journal.path!=notes.versions.journal.path!=tasks.versions.journal.path
        memory_put!(plain,"same","default value",ctx;expected_version=0)
        memory_put!(notes,"same","notes value",ctx;expected_version=0)
        memory_put!(tasks,"same","tasks value",ctx;expected_version=0)
        @test memory_get(plain,"same",ctx)["value"]["content"]=="default value"
        @test memory_get(notes,"same",ctx)["value"]["content"]=="notes value"
        @test memory_get(tasks,"same",ctx)["value"]["content"]=="tasks value"
        @test memory_namespaces(ctx)["namespaces"]==["default","notes","tasks"]
        @test memory_get(memory_store(ctx;namespace="empty"),"none",ctx)===nothing
        @test !isfile(memory_store(ctx;namespace="empty").versions.journal.path)
        for name in ["../escape","UpperCase","",repeat("x",65),"two words","a/b"]
            @test_throws ShenScopeError memory_store(ctx;namespace=name)
        end
        @test_throws ShenScopeError memory_put!(memory_store(ctx;namespace="invalid"),"key","text",ctx;expected_version=true)
        @test !("invalid" in memory_namespaces(ctx)["namespaces"])
        denied=memory_fixture_context(root;policy=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Deny)))
        @test_throws ShenScopeError memory_put!(memory_store(denied;namespace="denied"),"key","text",denied;expected_version=0)
        @test !("denied" in memory_namespaces(ctx)["namespaces"])
        for i in 1:29
            memory_fixture_put(ctx,"entry","value";namespace="n"*string(i))
        end
        @test length(memory_namespaces(ctx)["namespaces"])==32
        @test_throws ShenScopeError memory_fixture_put(ctx,"entry","value";namespace="overflow")
        @test !isfile(memory_store(ctx;namespace="overflow").versions.journal.path)
        second=memory_fixture_context(root;session_id="memory-second")
        @test memory_get(memory_store(second;namespace="notes"),"same",second)["value"]["content"]=="notes value"
        session_store=memory_store(ctx,:session;namespace="private")
        memory_put!(session_store,"secret","session fact",ctx;expected_version=0)
        @test memory_get(memory_store(second,:session;namespace="private"),"secret",second)===nothing
        mktempdir() do other_root
            other=RuntimeContext(other_root;state_dir=ctx.state_dir,session_id=ctx.session_id,
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow)))
            @test_throws ShenScopeError memory_get(session_store,"secret",other)
            @test_throws ShenScopeError memory_get(memory_store(other,:session;namespace="private"),"secret",other)
            memory_put!(memory_store(ctx,:user;namespace="preferences"),"theme","dark",ctx;expected_version=0)
            @test memory_get(memory_store(other,:user;namespace="preferences"),"theme",other)["value"]["content"]=="dark"
        end
    end
end

@testset "Memory corruption, source hashes and confined journal paths" begin
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx)
        entry=memory_fixture_put(ctx,"fact","content")
        @test entry["value"]["provenance_verified"]===false
        @test entry["value"]["origin_session_id"]==ctx.session_id
        @test entry["value"]["workspace_sha256"]==digest(ctx.root)
        memory_fixture_corrupt(store,ctx,records->(records[1]["value"]["content"]="tampered"))
        before=read(store.versions.journal.path)
        @test_throws ShenScopeError memory_get(store,"fact",ctx)
        @test_throws ShenScopeError memory_retrieve(store,"content",ctx)
        @test_throws ShenScopeError memory_put!(store,"new","safe",ctx;expected_version=0)
        @test read(store.versions.journal.path)==before
    end
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx)
        memory_fixture_put(ctx,"fact","content")
        open(store.versions.journal.path,"a") do io;write(io,"{\"partial\":");end
        @test_throws ShenScopeError memory_retrieve(store,"content",ctx)
    end
    if Sys.isunix()
        mktempdir() do root
            ctx=memory_fixture_context(root);store=memory_store(ctx)
            mkpath(dirname(store.versions.journal.path));outside=joinpath(root,"outside.jsonl");write(outside,"do not overwrite")
            symlink(outside,store.versions.journal.path)
            @test_throws ShenScopeError memory_put!(store,"key","content",ctx;expected_version=0)
            @test read(outside,String)=="do not overwrite"
        end
        mktempdir() do root
            ctx=memory_fixture_context(root);store=memory_store(ctx)
            memory_fixture_put(ctx,"key","content");outside=joinpath(root,"outside.lock");write(outside,"preserve")
            lockpath=store.versions.journal.path*".transaction.lock";rm(lockpath);symlink(outside,lockpath)
            @test_throws ShenScopeError memory_retrieve(store,"content",ctx)
            @test read(outside,String)=="preserve"
        end
    end
end
