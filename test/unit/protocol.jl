@testset "Bounded JSON-RPC framing and UTF-8 lengths" begin
    io=IOBuffer();value=Dict("jsonrpc"=>"2.0","id"=>1,"method"=>"health","params"=>Dict("text"=>"中文"))
    write_rpc(io,value);seekstart(io)
    @test read_rpc(io)==value
    @test read_rpc(io)===nothing
    @test_throws RPCFault read_rpc(IOBuffer("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}"))
    @test_throws RPCFault read_rpc(IOBuffer("Content-Length: 9\r\n\r\n{}"))
    @test_throws RPCFault read_rpc(IOBuffer("Content-Length: 99999999\r\n\r\n"))
    @test_throws RPCFault read_rpc(IOBuffer("Content-Length: 2\r\n\r\n[]"))
    @test_throws RPCFault read_rpc(IOBuffer("Content-Length: 2\r\n\r\nxx"))
    @test_throws RPCFault ShenScope.validate_rpc(Dict("jsonrpc"=>"2.0","id"=>true,"method"=>"health"))
end

@testset "Protocol version, config ownership, secrets and session commands" begin
    mktempdir() do root
        output=IOBuffer()
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output)
        @test_throws RPCFault dispatch_rpc(server,"health",Dict())
        @test_throws RPCFault dispatch_rpc(server,"initialize",Dict("protocol_version"=>"2.0"))
        hello=dispatch_rpc(server,"initialize",Dict("protocol_version"=>"1.0"))
        @test hello["capabilities"]["os_isolation"]==false
        session=dispatch_rpc(server,"sessions/create",Dict("title"=>"fixture"))
        id=session["id"]
        @test length(dispatch_rpc(server,"sessions/list",Dict()))==1
        @test dispatch_rpc(server,"sessions/get",Dict("session_id"=>id))["title"]=="fixture"
        config=dispatch_rpc(server,"config/get",Dict())
        config["value"]["permissions"]["network"]="deny"
        @test haskey(dispatch_rpc(server,"config/set",Dict("value"=>config["value"],"expected_sha256"=>config["sha256"])),"sha256")
        @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>config["value"],"expected_sha256"=>config["sha256"]))
        dispatch_rpc(server,"credentials/set",Dict("variable"=>"FIXTURE_SECRET","value"=>"fixture-sensitive-value"))
        @test dispatch_rpc(server,"credentials/status",Dict("variable"=>"FIXTURE_SECRET"))["configured"]
        @test !occursin("fixture-sensitive-value",canonical(dispatch_rpc(server,"config/get",Dict())))
        @test !occursin("fixture-sensitive-value",read(joinpath(root,"config.toml"),String))
        dispatch_rpc(server,"sessions/pin",Dict("session_id"=>id,"value"=>true))
        @test dispatch_rpc(server,"sessions/get",Dict("session_id"=>id))["metadata"]["pinned"]
        branch=dispatch_rpc(server,"sessions/branch",Dict("session_id"=>id,"through"=>0))
        @test branch["metadata"]["parent"]==id
        dispatch_rpc(server,"sessions/archive",Dict("session_id"=>id))
        @test length(dispatch_rpc(server,"sessions/list",Dict()))==1
        @test_throws RPCFault dispatch_rpc(server,"unknown",Dict())
        stop_server!(server)
        @test isempty(server.credentials)
    end
end

@testset "Agent protocol permission ownership and cancellation" begin
    mktempdir() do root
        output=IOBuffer()
        provider=MockProvider([response(;calls=[ToolCall("write",Dict("path"=>"created.txt","content"=>"approved"))]),response("done")])
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output,
            provider_factory=s->provider)
        dispatch_rpc(server,"initialize",Dict())
        id=dispatch_rpc(server,"sessions/create",Dict())["id"]
        dispatch_rpc(server,"agent/start",Dict("session_id"=>id,"prompt"=>"create file"))
        deadline=time()+15
        while isempty(server.approvals) && haskey(server.runs,id) && time()<deadline;sleep(0.025);end
        @test length(server.approvals)==1
        request_id=first(keys(server.approvals))
        @test !isfile(joinpath(root,"created.txt"))
        @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("request_id"=>request_id,"session_id"=>"foreign","decision"=>"once"))
        dispatch_rpc(server,"permissions/respond",Dict("request_id"=>request_id,"session_id"=>id,"decision"=>"once"))
        while haskey(server.runs,id) && time()<deadline;sleep(0.025);end
        @test read(joinpath(root,"created.txt"),String)=="approved"
        @test load_session(server.state_dir,id).status==:complete
        server.provider_factory=s->MockProvider([response("long output")];delay=0.1)
        dispatch_rpc(server,"agent/start",Dict("session_id"=>id,"prompt"=>"wait"))
        sleep(0.15)
        dispatch_rpc(server,"agent/cancel",Dict("session_id"=>id))
        while haskey(server.runs,id) && time()<deadline;sleep(0.025);end
        @test load_session(server.state_dir,id).status==:cancelled
        @test isempty(server.approvals)
        stop_server!(server)
    end
end
