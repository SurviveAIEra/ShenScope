@testset "Julia project RPC keeps approvals, ownership and syntax evidence explicit" begin
    mktempdir() do root
        write(joinpath(root,"a.jl"),"module Demo\nf(x::Int,y)=x\nf(x,y::Int)=y\nend\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            capabilities=dispatch_rpc(server,"project/backends",Dict())
            julia=only([value for value in capabilities if value["name"]=="julia_syntax"])
            @test julia["languages"]==["julia"] && !julia["types"] && !julia["references"]
            id=dispatch_rpc(server,"sessions/create",Dict("title"=>"Julia source"))["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Other session"))["id"]
            job=dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"julia_syntax","action"=>"build"))["job_id"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError dispatch_rpc(server,"project/cancel",Dict("session_id"=>foreign,"job_id"=>job))
            answered=Set{String}();categories=Symbol[];deadline=time()+120
            while dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))["status"]=="running" && time()<deadline
                for (request,(owner,_)) in collect(server.approvals)
                    request in answered && continue
                    @test owner==id
                    frames=IOBuffer(take!(server.output))
                    while !eof(frames)
                        message=ShenScope.read_rpc(frames)
                        get(message,"method",nothing)=="agent/event" || continue
                        event=message["params"]
                        get(event,"kind",nothing)=="permission_request" || continue
                        push!(categories,Symbol(event["payload"]["category"]))
                    end
                    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"session"))
                    push!(answered,request)
                end
                sleep(0.01)
            end
            finished=dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))
            @test finished["status"]=="complete"
            @test :persistence in categories && !(:process in categories) && !(:network in categories)
            params=Dict("session_id"=>id,"backend"=>"julia_syntax","action"=>"julia_dispatch","query"=>"Demo.f")
            evidence=dispatch_rpc(server,"project/query",params)
            @test !evidence["compiler_confirmed"] && only(evidence["items"])["method_count"]==2
            @test only(only(evidence["items"])["pairs"])["classification"]=="crossed_annotation_pattern"
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",merge(params,Dict("revision"=>0)))
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",merge(params,Dict("action"=>"hover","symbol_id"=>first(only(evidence["items"])["methods"])["id"])))
            server.contexts[id].permissions.rules[:read]=Deny
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",params)
        finally
            ShenScope.stop_server!(server)
        end
    end
end

@testset "Julia CLI query arguments carry bounded filters and revision checks" begin
    values=["project","julia_dispatch","Demo.f","--backend","julia_syntax","--max-pairs","10","--revision","1","--limit","2"]
    positional,flags=ShenScope.parse_cli(values)
    arguments=ShenScope.cli_project_arguments(positional,flags)
    ShenScope.validate_tool_arguments(ProjectTool(),arguments)
    @test arguments["query"]=="Demo.f" && arguments["max_pairs"]==10 && arguments["revision"]==1
    @test arguments["backend"]=="julia_syntax" && arguments["limit"]==2
    positional,flags=ShenScope.parse_cli(["project","julia_dispatch","--max-pairs","bad"])
    @test_throws ShenScopeError ShenScope.cli_project_arguments(positional,flags)
end
