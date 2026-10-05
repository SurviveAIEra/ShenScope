@testset "Language result publication rechecks secondary sources and live permission" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"main.py"),"value = 1\n");write(joinpath(root,"other.py"),"value = 2\n")
        primary=read_workspace_snapshot(ctx,"main.py";unicode_line_separators=false)
        sources=ShenScope.LanguageResultSources(ctx;primary)
        peer=ShenScope.language_result_source!(sources,ShenScope.mcp_file_uri(joinpath(root,"other.py")))
        @test length(ShenScope.verify_language_result_sources!(sources))==2
        write(peer.absolute,"external = 3\n")
        @test_throws ShenScopeError ShenScope.verify_language_result_sources!(sources)
        write(peer.absolute,peer.source.source)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError ShenScope.verify_language_result_sources!(sources)
    end
end

@testset "Navigation selected pages reject stale secondary files without claiming full-graph freshness" begin
    mktempdir() do root
        ctx=model_context(root);write(joinpath(root,"first.go"),"package p\n");write(joinpath(root,"second.go"),"package p\n")
        state=ProjectState(ctx,GoASTBackend())
        for path in ("first.go","second.go")
            text=read(joinpath(root,path),String)
            state.files[path]=FileFacts(path,digest(text),CodeSymbol[],Relation[],ShenScope.CallReference[],Dict{String,Any}[])
        end
        page=Dict{String,Any}("revision"=>state.revision,"items"=>[Dict("location"=>Dict("file"=>"second.go"))])
        ShenScope.verify_project_navigation_page!(state,page,ctx)
        @test only(page["source_versions"])["path"]=="second.go"
        @test page["selected_source_versions_verified"] && !page["whole_project_source_versions_verified"]
        write(joinpath(root,"first.go"),"unselected source changed\n")
        @test ShenScope.verify_project_navigation_page!(state,page,ctx)===page
        write(joinpath(root,"second.go"),"selected source changed\n")
        @test_throws ShenScopeError ShenScope.verify_project_navigation_page!(state,page,ctx)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError ShenScope.verify_project_navigation_page!(state,page,ctx)
    end
end

@testset "Project retained jobs stop revealing data after read revocation" begin
    mktempdir() do root
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict());sid=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"];ctx=ShenScope.server_context(server,sid)
            manager=ShenScope.server_project_tool(server).manager
            id=string(Base.UUID(9));job=Dict{String,Any}("id"=>id,"status"=>"running","session_id"=>sid,
                "backend"=>"go_ast","action"=>"impact","context"=>ShenScope.child_context(ctx))
            manager.jobs[id]=job;ShenScope.finish_project_job!(manager,job,Dict("sensitive"=>"retained source"))
            params=Dict("session_id"=>sid,"job_id"=>id)
            @test dispatch_rpc(server,"project/job",params)["result"]["sensitive"]=="retained source"
            ctx.permissions.rules[:read]=Deny
            view=dispatch_rpc(server,"project/job",params)
            @test view["result"]===nothing && view["result_hidden_by_permission"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/job",Dict("session_id"=>foreign,"job_id"=>id))
            @test dispatch_rpc(server,"project/cancel",params)["result"]===nothing
            @test !iscancelled(ctx.cancellation)
            for (kind,payload,key) in ((:project_completed,Dict("result"=>Dict("secret"=>"source")),"result"),
                    (:project_failed,Dict("message"=>"private path"),"result"),
                    (:tool_completed,Dict("name"=>"project","value"=>Dict("secret"=>"source")),"value"))
                event=AgentEvent(1,kind,sid,"trace","now",payload)
                truncate(server.output,0);seekstart(server.output)
                ShenScope.server_event(server,event);seekstart(server.output)
                delivered=read_rpc(server.output)["params"]["payload"]
                @test delivered[key]===nothing && delivered["result_hidden_by_permission"]
                @test !occursin("private path",ShenScope.canonical(delivered))
            end
        finally
            stop_server!(server)
        end
    end
end

@testset "Unicode scalar columns use valid boundaries and reject invalid offsets" begin
    source=SourceMap("unicode.txt","a😀中b\r\n";unicode_line_separators=false)
    @test [ShenScope.scalar_byte_column(source,1,index) for index in 0:4]==[1,2,6,9,10]
    @test_throws ShenScopeError ShenScope.scalar_byte_column(source,1,5)
    @test_throws ShenScopeError ShenScope.scalar_byte_column(source,1,true)
end
