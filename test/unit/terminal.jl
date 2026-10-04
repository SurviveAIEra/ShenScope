@testset "Terminal byte cursors retain Unicode and make output loss explicit" begin
    journal=TerminalJournal(1024)
    ShenScope.terminal_append!(journal,"a中文🙂z";observed=12)
    page=terminal_page(journal;max_bytes=5)
    @test page["text"]=="a中" && page["next_offset"]==4 && page["more"]
    @test terminal_page(journal;offset=4)["text"]=="文🙂z"
    @test_throws ShenScopeError terminal_page(journal;offset=2)
    @test_throws ShenScopeError terminal_page(journal;offset=999)
    @test_throws ShenScopeError terminal_page(journal;offset=true)
    ShenScope.terminal_append!(journal,repeat("中文🙂",300);observed=3000)
    retained=terminal_page(journal)
    @test retained["lost_bytes"]>0 && isvalid(retained["text"])
    @test ncodeunits(retained["text"])<=1024 && retained["observed_raw_bytes"]==3012
    @test terminal_page(journal;offset=retained["next_offset"])["text"]==""
end

@testset "Streaming terminal filtering removes control strings across chunk boundaries" begin
    filter=ShenScope.TerminalFilter()
    output=ShenScope.terminal_filter!(filter,Vector{UInt8}(codeunits("A\e]52;c;clipboard")))
    output*=ShenScope.terminal_filter!(filter,Vector{UInt8}(codeunits("\e\\B\e[31m中文\e[0m\ePprivate")))
    output*=ShenScope.terminal_filter!(filter,Vector{UInt8}(codeunits("\e\\C\e[8;99;99tD\0"));final=true)
    @test output=="AB\e[31m中文\e[0mCD"
    @test ShenScope.terminal_plain_text(output)=="AB中文CD"
    @test filter.discarded_bytes>20
    utf=ShenScope.TerminalFilter()
    @test ShenScope.terminal_filter!(utf,UInt8[0xe4])==""
    @test ShenScope.terminal_filter!(utf,UInt8[0xb8,0xad];final=true)=="中"
    long=ShenScope.TerminalFilter()
    ShenScope.terminal_filter!(long,Vector{UInt8}(codeunits("\e["*repeat("1",1000))))
    @test isempty(long.sequence)
    @test ShenScope.terminal_filter!(long,UInt8['m','x'];final=true)=="x"
    @test_throws ShenScopeError TerminalSize(1,80)
    @test_throws ShenScopeError TerminalSize(true,80)
    @test_throws ShenScopeError TerminalJournal(4)
    c1=ShenScope.TerminalFilter()
    @test ShenScope.terminal_filter!(c1,Vector{UInt8}(codeunits("a\u009d52;c;secret\u009cb"));final=true)=="ab"
end
