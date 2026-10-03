@testset "Terminal rendering sanitizes control sequences and handles wide text" begin
    @test ShenScope.terminal_safe("\e[31mred\e[0m") == "red"
    @test ShenScope.terminal_safe("\e]52;c;clipboard\aok") == "ok"
    @test ShenScope.terminal_safe("hello\x03world") == "helloworld"
    @test ShenScope.terminal_crop("中文abcd",5)=="中文a"
    pending=UInt8[];bytes=collect(codeunits("中文"))
    @test isempty(ShenScope.terminal_decode!(pending,bytes[1:2]))
    @test ShenScope.terminal_decode!(pending,bytes[3:end])==['中','文']
    @test isempty(pending)
    state=ShenScope.TerminalState()
    for char in "任务";ShenScope.terminal_key!(state,char);end
    @test String(copy(state.draft))=="任务"
    @test ShenScope.terminal_key!(state,'\r')==:send
    ShenScope.terminal_key!(state,'\x7f')
    @test String(copy(state.draft))=="任"
    @test ShenScope.terminal_key!(state,'\x03')==:cancel
    @test ShenScope.terminal_key!(state,'\x04')==:quit
    ShenScope.terminal_push!(state,"safe\e[2J")
    @test state.lines==["safe"]
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        frame=ShenScope.terminal_frame(state,ctx,12,60)
        @test occursin("ShenScope",frame)
        @test occursin("Tokens 0",frame)
        @test !occursin("\e[2J",frame)
    end
end
