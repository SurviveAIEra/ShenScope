@testset "Memory lexical grammar and UTF-8 witness coordinates" begin
    text="中文🙂 Straße İ ABC_12"
    tokens=memory_tokens(text)
    @test !tokens.truncated
    @test [token.value for token in tokens.tokens]==["中","文","中文","straße","i","abc_12"]
    for token in tokens.tokens
        @test isvalid(SubString(text,token.start_byte,prevind(text,token.end_byte)))
        @test lowercase(String(SubString(text,token.start_byte,prevind(text,token.end_byte))))==token.value
    end
    query=memory_query("alpha +beta -gamma \"中文 graph\" -\"not here\"")
    @test "alpha" in query.optional
    @test query.required==("beta",)
    @test query.excluded==("gamma",)
    @test query.phrases==("中文 graph",)
    @test query.excluded_phrases==("not here",)
    @test !("not" in query.excluded)
    @test isempty(memory_query(" ").optional)
    for bad in ["+","- foo","\"unfinished","\"a\"b","\"\"","\"bad\\n\"",repeat("x",129),"🙂"]
        @test_throws ShenScopeError memory_query(bad)
    end
    @test memory_tokens("中文";limit=2).truncated
    @test memory_tokens(repeat("x",129)).dropped_tokens==1
    @test_throws ArgumentError memory_tokens("text";limit=true)
    @test_throws ArgumentError memory_tokens("text";max_term_bytes=false)
    @test_throws ShenScopeError MemoryFilters(;sources=["verified"])
    @test_throws ShenScopeError MemoryFilters(;include_deleted=1)
    @test_throws ShenScopeError MemoryFilters(;updated_after="2026-02-30T00:00:00.000Z")
    @test_throws ShenScopeError MemoryRetrievalOptions(;offset=true)
    @test_throws ShenScopeError MemoryRetrievalOptions(;limit=101)
    @test_throws ShenScopeError MemoryRetrievalOptions(;cursor="x")
end

@testset "Memory BM25F independent numeric oracle and declared provenance" begin
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx)
        memory_fixture_put(ctx,"a","alpha alpha";title="Alpha")
        memory_fixture_put(ctx,"b","alpha";title="Beta",source="agent")
        result=memory_retrieve(store,"alpha",ctx)
        @test [item["key"] for item in result["items"]]==["a","b"]
        idf=log1p(0.5/2.5)
        # Title averages one token; body averages 1.5. Calculate both field
        # normalizations directly, without calling the production scorer.
        a_frequency=2.0+2/(0.25+0.75*2/1.5)
        b_frequency=1/(0.25+0.75*1/1.5)
        @test isapprox(result["items"][1]["score"],idf*2.2*a_frequency/(1.2+a_frequency);atol=1e-12)
        @test isapprox(result["items"][2]["score"],idf*2.2*b_frequency/(1.2+b_frequency);atol=1e-12)
        @test result["scoring"]["population"]==2
        @test result["scoring"]["calibrated_confidence"]===false
        @test result["coverage"]["complete"]
        @test result["writes_performed"]===false
        @test result["model_requests"]==0
        for item in result["items"]
            @test item["citation"]["version"]==1
            @test item["citation"]["snapshot"]==result["snapshot"]
            @test item["provenance_verified"]===false
            @test isapprox(sum(term["score"] for term in item["contributions"]),item["score"];atol=1e-12)
        end
        user_only=memory_retrieve(store,"alpha",ctx;options=MemoryRetrievalOptions(;filters=MemoryFilters(;sources=["user"])))
        @test [item["key"] for item in user_only["items"]]==["a"]
        @test user_only["scoring"]["population"]==1
        @test user_only["items"][1]["contributions"][1]["document_frequency"]==1
    end
end

@testset "Memory filtering, exact phrases, exclusions and expiry" begin
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx)
        memory_fixture_put(ctx,"a","julia graph reliable";tags=["core","julia"])
        memory_fixture_put(ctx,"b","julia not elsewhere";tags=["core"],source="agent")
        memory_fixture_put(ctx,"c","python graph";tags=["tests"])
        memory_fixture_put(ctx,"d","julia not here";tags=["private"])
        @test [item["key"] for item in memory_retrieve(store,"+julia -reliable",ctx)["items"]]==["b","d"]
        @test [item["key"] for item in memory_retrieve(store,"\"julia graph\"",ctx)["items"]]==["a"]
        @test Set(item["key"] for item in memory_retrieve(store,"julia -\"not here\"",ctx)["items"])==Set(["a","b"])
        all_terms=memory_retrieve(store,"julia graph",ctx;options=MemoryRetrievalOptions(;match=:all))
        @test [item["key"] for item in all_terms["items"]]==["a"]
        tags=memory_retrieve(store,"",ctx;options=MemoryRetrievalOptions(;sort=:key,filters=MemoryFilters(;tags_all=["core","julia"])))
        @test [item["key"] for item in tags["items"]]==["a"]
        any_tags=memory_retrieve(store,"",ctx;options=MemoryRetrievalOptions(;sort=:key,filters=MemoryFilters(;tags_any=["julia","tests"])))
        @test [item["key"] for item in any_tags["items"]]==["a","c"]
        expiry=time()+60;memory_fixture_put(ctx,"temporary","julia temporary";expires=expiry)
        @test !("temporary" in [item["key"] for item in memory_retrieve(store,"julia",ctx;at=expiry+1)["items"]])
        expired=memory_retrieve(store,"temporary",ctx;at=expiry+1,options=MemoryRetrievalOptions(;filters=MemoryFilters(;include_expired=true)))
        @test expired["items"][1]["expired"]
        memory_delete!(store,"c",ctx;expected_version=1)
        deleted=memory_retrieve(store,"",ctx;options=MemoryRetrievalOptions(;sort=:key,filters=MemoryFilters(;include_deleted=true)))
        @test only(item for item in deleted["items"] if item["key"]=="c")["deleted"]
        inventory=memory_inventory(store,ctx;at=expiry+1)
        @test inventory["live"]==3 && inventory["expired"]==1 && inventory["deleted"]==1
        @test !inventory["secure_erasure"]
        @test length(memory_history(store,"c",ctx))==2
    end
end

@testset "Pinned memory pagination, Unicode snippets and cache retirement" begin
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx);manager=MemoryManager(;max_indexes=1)
        for key in ["a","b","c"];memory_fixture_put(ctx,key,"中文 graph "*key);end
        first_page=memory_retrieve(store,"中文",ctx;manager,options=MemoryRetrievalOptions(;sort=:key,limit=1))
        @test first_page["items"][1]["key"]=="a"
        second_page=memory_retrieve(store,"中文",ctx;manager,options=MemoryRetrievalOptions(;sort=:key,limit=1,cursor=first_page["next_cursor"]))
        @test second_page["items"][1]["key"]=="b"
        @test first_page["as_of"]==second_page["as_of"]
        @test_throws ShenScopeError memory_retrieve(store,"different",ctx;manager,
            options=MemoryRetrievalOptions(;sort=:key,cursor=first_page["next_cursor"]))
        memory_put!(store,"a","updated 中文 graph",ctx;expected_version=1)
        @test_throws ShenScopeError memory_retrieve(store,"中文",ctx;manager,
            options=MemoryRetrievalOptions(;sort=:key,cursor=first_page["next_cursor"]))
        @test_throws ShenScopeError memory_retrieve(store,"中文",ctx;options=MemoryRetrievalOptions(;expected_snapshot=first_page["snapshot"]))
        text=repeat("前缀",300)*" 中文 Graph "*repeat("尾部",300)
        memory_fixture_put(ctx,"snippet",text)
        result=memory_retrieve(store,"+graph",ctx;options=MemoryRetrievalOptions(;snippet_chars=40))
        snippet=only(item for item in result["items"] if item["key"]=="snippet")["snippet"]
        @test isvalid(snippet["text"]) && length(snippet["text"])==40
        @test snippet["leading_omitted"] && snippet["trailing_omitted"]
        for witness in snippet["highlights"]
            original=String(Vector{UInt8}(codeunits(snippet["text"])[witness["start_byte"]+1:witness["end_byte"]]))
            @test lowercase(original)==witness["term"]
        end
        other=memory_store(ctx;namespace="other");memory_fixture_put(ctx,"fact","different";namespace="other")
        memory_retrieve(other,"different",ctx;manager)
        @test length(manager.indexes)==1
        @test only(values(manager.indexes)).snapshot.store.namespace=="other"
        cleanup_memory!(manager)
        @test isempty(manager.indexes)
        @test_throws ShenScopeError memory_retrieve(store,"graph",ctx;manager)
    end
end

@testset "Memory partial coverage remains explicit and cancellation publishes nothing" begin
    mktempdir() do root
        ctx=memory_fixture_context(root);store=memory_store(ctx)
        memory_fixture_put(ctx,"a","alpha beta secret";title="alpha")
        snapshot=memory_snapshot(store,ctx)
        index=memory_build_index(snapshot,ctx;max_tokens=2,max_postings=1)
        @test !isempty(index.partial_documents)
        @test index.posting_count==1
        result=ShenScope.memory_rank(index,memory_query("alpha -secret"),MemoryRetrievalOptions(),ctx)
        @test isempty(result.ranked)
        canceled=memory_fixture_context(root);cancel!(canceled.cancellation)
        @test_throws ShenScopeError memory_retrieve(memory_store(canceled),"alpha",canceled)
        before=read(store.versions.journal.path)
        @test_throws ShenScopeError memory_put!(memory_store(canceled),"new","value",canceled;expected_version=0)
        @test read(store.versions.journal.path)==before
    end
end
