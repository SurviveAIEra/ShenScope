@testset "Problem RPC keeps ownership, cancellation and current Read gates" begin
    mktempdir() do root
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            sid=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            owner=ShenScope.server_context(server,sid)
            tool=ShenScope.server_problems_tool(server)
            snapshot=retain_problem_snapshot!(tool.manager,owner,"fixture",0,ProblemFileReport[])
            @test dispatch_rpc(server,"problems/query",Dict("session_id"=>sid,"action"=>"get","snapshot_id"=>snapshot.id))["snapshot_id"]==snapshot.id
            @test_throws ShenScopeError dispatch_rpc(server,"problems/query",Dict("session_id"=>foreign,"action"=>"get","snapshot_id"=>snapshot.id))
            @test_throws RPCFault dispatch_rpc(server,"problems/query",Dict("session_id"=>sid,"action"=>"capture","backend"=>"typescript"))
            owner.permissions.rules[:read]=Ask
            started=dispatch_rpc(server,"problems/start",Dict("session_id"=>sid,"action"=>"list"))
            @test timedwait(()->!isempty(server.approvals),5;pollint=0.01)==:ok
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>sid,"title"=>"busy"))
            config=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>config["value"],"expected_sha256"=>config["sha256"]))
            @test_throws ShenScopeError dispatch_rpc(server,"problems/cancel",Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
            dispatch_rpc(server,"problems/cancel",Dict("session_id"=>sid,"job_id"=>started["job_id"]))
            @test timedwait(()->isempty(server.approvals),5;pollint=0.01)==:ok
            @test timedwait(()->ShenScope.owned_operation(tool.operations,started["job_id"],owner)["status"]!="running",5)==:ok
            @test !iscancelled(owner.cancellation)
            owner.permissions.rules[:read]=Allow
            read_job=dispatch_rpc(server,"problems/start",Dict("session_id"=>sid,"action"=>"get","snapshot_id"=>snapshot.id))
            @test timedwait(()->dispatch_rpc(server,"problems/job",Dict("session_id"=>sid,"job_id"=>read_job["job_id"]))["status"]=="complete",5)==:ok
            owner.permissions.rules[:read]=Deny
            @test dispatch_rpc(server,"problems/job",Dict("session_id"=>sid,"job_id"=>read_job["job_id"]))["result"]===nothing
            @test_throws ShenScopeError dispatch_rpc(server,"problems/query",Dict("session_id"=>sid,"action"=>"get","snapshot_id"=>snapshot.id))
            @test haskey(tool_schema(only(filter(t->tool_name(t)=="problems",core_tools())))["properties"],"action")
        finally
            stop_server!(server)
        end
    end
end
