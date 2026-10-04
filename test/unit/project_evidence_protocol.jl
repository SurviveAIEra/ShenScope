@testset "Combined evidence RPC owns jobs and asks only for the bounded read" begin
    mktempdir() do root
        fixture=evidence_fixture(root)
        for state in fixture.states
            changes=Dict{String,Union{Nothing,FileFacts}}(path=>facts for (path,facts) in state.files)
            state.revision=0;ShenScope.persist_delta!(state,changes);state.revision=1
        end
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='ask'\npersistence='deny'\nprocess='deny'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=fixture.ctx.state_dir,config_file=config,output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            id=dispatch_rpc(server,"sessions/create",Dict("title"=>"Combined evidence"))["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Other"))["id"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",Dict("session_id"=>id,"action"=>"evidence_status"))
            args=Dict{String,Any}("session_id"=>id,"action"=>"evidence_compare","backends"=>["go_ast","tree_sitter"])
            job=dispatch_rpc(server,"project/start",args)["job_id"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/job",Dict("session_id"=>foreign,"job_id"=>job))
            @test_throws ShenScopeError dispatch_rpc(server,"project/cancel",Dict("session_id"=>foreign,"job_id"=>job))
            deadline=time()+120;approvals=0;categories=Symbol[]
            while dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))["status"]=="running" && time()<deadline
                for (request,(owner,_)) in collect(server.approvals)
                    @test owner==id
                    frames=IOBuffer(take!(server.output))
                    while !eof(frames)
                        message=ShenScope.read_rpc(frames)
                        get(message,"method",nothing)=="agent/event" || continue
                        event=message["params"];event["kind"]=="permission_request" || continue
                        push!(categories,Symbol(event["payload"]["category"]))
                    end
                    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"session"))
                    approvals+=1
                end
                sleep(0.01)
            end
            result=dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))
            @test result["status"]=="complete" && result["backend"]=="combined_evidence"
            @test approvals==1 && categories==[:read]
            @test result["result"]["action"]=="evidence_compare" && result["result"]["total"]==1
            status=dispatch_rpc(server,"project/query",Dict("session_id"=>id,"action"=>"evidence_status"))
            @test count(source->source["indexed"],status["sources"])==2
            context=server.contexts[id]
            context.permissions=PermissionPolicy(;rules=Dict(:read=>Ask,:persistence=>Deny,:process=>Deny,:network=>Deny))
            cancelled=dispatch_rpc(server,"project/start",args)["job_id"]
            @test timedwait(()->!isempty(server.approvals),30)==:ok
            dispatch_rpc(server,"project/cancel",Dict("session_id"=>id,"job_id"=>cancelled))
            @test timedwait(()->dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>cancelled))["status"]!="running",30)==:ok
            @test isempty(server.approvals)
            context.permissions.rules[:read]=Deny
            @test_throws ShenScopeError dispatch_rpc(server,"project/query",Dict("session_id"=>id,"action"=>"evidence_status"))
        finally
            ShenScope.stop_server!(server)
        end
    end
end

@testset "Evidence CLI separates changed paths from captured scope" begin
    positional,flags=ShenScope.parse_cli(["project","evidence_impact","a.go","--backends","tree_sitter,go_ast",
        "--scope-paths","a.go,b.go","--no-evidence-bridges","--max-depth","3"])
    args=ShenScope.cli_project_arguments(positional,flags)
    ShenScope.validate_tool_arguments(ProjectTool(),args)
    @test args["paths"]==["a.go"] && args["scope_paths"]==["a.go","b.go"]
    @test args["backends"]==["tree_sitter","go_ast"] && !args["include_bridges"] && args["max_depth"]==3
end
