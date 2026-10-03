@testset "Incremental process UTF-8 boundaries and malformed byte recovery" begin
    source="ASCII 中文🙂é\n⠿終"
    bytes=collect(codeunits(source))
    for split in 0:length(bytes)
        decoder=ShenScope.UTF8StreamDecoder()
        first=ShenScope.feed_utf8!(decoder,bytes[1:split])
        second=ShenScope.feed_utf8!(decoder,bytes[split+1:end])
        final=ShenScope.finish_utf8!(decoder)
        @test first*second*final==source
        @test isvalid(first) && isvalid(second) && isvalid(final)
        @test isempty(decoder.pending)
    end
    decoder=ShenScope.UTF8StreamDecoder(); output=IOBuffer()
    for byte in bytes
        write(output,ShenScope.feed_utf8!(decoder,[byte]))
        @test length(decoder.pending)<=3
    end
    @test String(take!(output))*ShenScope.finish_utf8!(decoder)==source
    for malformed in (UInt8[0xff,0x41],UInt8[0xc0,0xaf],UInt8[0xed,0xa0,0x80],UInt8[0xf4,0x90,0x80,0x80],UInt8[0xe2,0x82])
        decoder=ShenScope.UTF8StreamDecoder()
        text=ShenScope.feed_utf8!(decoder,malformed)*ShenScope.finish_utf8!(decoder)
        @test isvalid(text)
        @test occursin('�',text)
        @test ShenScope.finish_utf8!(decoder)==""
        @test_throws ShenScopeError ShenScope.feed_utf8!(decoder,UInt8[])
    end
end

@testset "Actual fragmented stdout and stderr match retained process output" begin
    mktempdir() do root
        events=AgentEvent[]
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(:process=>Allow)),sink=event->push!(events,event))
        code="import os,time\ndata='中文🙂é'.encode()\nfor stream in (1,2):\n for byte in data:\n  os.write(stream,bytes([byte]));time.sleep(.01)\n"
        result=execute(ProcessTool(),Dict("action"=>"run","argv"=>["python3","-B","-c",code],"timeout"=>10),ctx)
        for stream in ("stdout","stderr")
            text=join(event.payload["text"] for event in events if event.kind==:process_output && event.payload["stream"]==stream)
            @test text=="中文🙂é"
            @test text==result[stream]
            @test !occursin('�',text)
        end
        @test result["exit_code"]==0
    end
end
