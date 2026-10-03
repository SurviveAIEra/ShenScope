@testset "Headless CLI, offline task and session lifecycle" begin
    mktempdir() do root
        script=joinpath(root,"script.json")
        state=joinpath(root,"state")
        write(script,canonical([Dict("text"=>"离线任务完成")]))
        @test ShenScope.main(["chat","验证离线运行","--root",root,"--state-dir",state,"--script",script,"--json"])==0
        sessions=list_sessions(state)
        @test length(sessions)==1
        id=sessions[1]["id"]
        @test load_session(state,id).status==:complete
        @test ShenScope.main(["sessions","rename",id,"CLI fixture","--state-dir",state])==0
        @test load_session(state,id).title=="CLI fixture"
        @test ShenScope.main(["sessions","archive",id,"--state-dir",state])==0
        @test isempty(list_sessions(state))
        @test ShenScope.main(["chat","task","--unknown"])==1
        @test ShenScope.cli_approval(PermissionRequest("fixture",:edit,"edit","file","fixture"))==:deny
    end
end
