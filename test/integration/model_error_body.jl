using HTTP,Sockets

@testset "Fragmented HTTP error envelopes classify only complete bounded structured context errors" begin
    for (label,body,expected) in (("context",ShenScope.canonical(Dict("error"=>Dict("code"=>"context_length_exceeded","message"=>"PRIVATE FIXTURE DETAILS"))),:context_overflow),
            ("plain","maximum context length",:request),("oversized",repeat("x",65537),:request),
            ("incomplete","{\"error\":{\"code\":\"context_length_exceeded\"}",:request))
        listener=listen(ip"127.0.0.1",0);port=getsockname(listener)[2]
        handler=input->begin
            read(input)
            HTTP.setstatus(input,400);HTTP.setheader(input,"Content-Type"=>"application/json")
            HTTP.setheader(input,"Content-Length"=>string(ncodeunits(body)));HTTP.startwrite(input)
            sleep(0.03)
            bytes=codeunits(body)
            for start in 1:4096:length(bytes)
                write(input,bytes[start:min(start+4095,length(bytes))]);flush(input)
                sleep(0.005)
            end
        end
        server=HTTP.serve!(handler,listener;stream=true,verbose=false)
        try
            mktempdir() do root
                ctx=RuntimeContext(root;state_dir=joinpath(root,"state"));ctx.permissions.rules[:network]=Allow
                provider=HTTPProvider(ProviderConfig(;endpoint="http://127.0.0.1:$port",retries=0,timeout=10.0))
                request=ModelRequest([Message(:user,"fixture")],Dict{String,Any}[],64,Dict{String,Any}())
                failure=try;stream_chat(provider,request,(kind,payload)->nothing,ctx);nothing;catch error;error;end
                @test failure isa ShenScopeError
                @test failure.code==expected
                @test !occursin("PRIVATE FIXTURE DETAILS",failure.message)
            end
        finally;close(server);end
    end
end
