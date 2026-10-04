function captured_memory_cli(args,root)
    path=joinpath(root,"cli-output.txt")
    code=open(path,"w") do output
        redirect_stdout(output) do
            ShenScope.main(args)
        end
    end
    (;code,text=read(path,String))
end

@testset "Memory CLI independently persists, filters and checks stale versions" begin
    mktempdir() do root
        write(joinpath(root,"note.txt"),"Julia 中文代码图 references")
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\npersistence='deny'\nnetwork='deny'\nprocess='deny'\n")
        flags=["--root",root,"--state-dir",joinpath(root,"state"),"--config",config,"--namespace","notes"]
        denied=captured_memory_cli(["memory","put","graph","note.txt","--expected-version","0",flags...],root)
        @test denied.code==1
        ctx=memory_fixture_context(root)
        @test memory_get(memory_store(ctx;namespace="notes"),"graph",ctx)===nothing
        saved=captured_memory_cli(["memory","put","graph","note.txt","--expected-version","0","--tags","core,julia",
            "--allow-persistence",flags...],root)
        @test saved.code==0
        @test parsejson(saved.text)["value"]["source"]=="user"
        @test parsejson(saved.text)["version"]==1
        found=captured_memory_cli(["memory","retrieve","代码图","--tags-all","core","--match","all",flags...],root)
        @test found.code==0
        @test parsejson(found.text)["items"][1]["key"]=="graph"
        @test parsejson(found.text)["coverage"]["complete"]
        @test captured_memory_cli(["memory","list","--limit","true",flags...],root).code==1
        @test captured_memory_cli(["memory","put","graph","note.txt","--allow-persistence",flags...],root).code==1
        @test captured_memory_cli(["memory","put","graph","note.txt","--expected-version","0","--allow-persistence",flags...],root).code==1
        inspected=captured_memory_cli(["memory","get","graph",flags...],root)
        @test inspected.code==0 && parsejson(inspected.text)["version"]==1
        history=captured_memory_cli(["memory","history","graph",flags...],root)
        @test history.code==0 && length(parsejson(history.text))==1
        export_data=captured_memory_cli(["memory","export",flags...],root)
        @test export_data.code==0 && parsejson(export_data.text)["namespace"]=="notes"
        write(joinpath(root,"export.json"),export_data.text)
        imported=captured_memory_cli(["memory","import","export.json","--allow-persistence",flags[1:end-1]...,"other"],root)
        @test imported.code==0 && parsejson(imported.text)["count"]==1
        @test captured_memory_cli(["memory","status","--scope","session",flags...],root).code==1
        deleted=captured_memory_cli(["memory","delete","graph","--expected-version","1","--allow-persistence",flags...],root)
        @test deleted.code==0 && parsejson(deleted.text)["deleted"]
        @test memory_get(memory_store(ctx;namespace="notes"),"graph",ctx)===nothing
    end
end
