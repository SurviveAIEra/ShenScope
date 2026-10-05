@testset "Owned compiler jobs protect conversations, cancel pending approval and retire" begin
    mktempdir() do root
        output=IOBuffer();server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output)
        try
            hello=dispatch_rpc(server,"initialize",Dict())
            @test hello["capabilities"]["structured_compiler_ir"]
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict())["id"]
            targets=dispatch_rpc(server,"diagnostics/query",Dict("session_id"=>owner,"action"=>"targets"))
            @test any(item->item["name"]=="digest_string",targets)
            @test_throws RPCFault dispatch_rpc(server,"diagnostics/query",Dict("session_id"=>owner,"action"=>"compile","target"=>"digest_string"))
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/start",Dict("session_id"=>owner,"action"=>"compile","target"=>"Base.eval"))
            started=dispatch_rpc(server,"diagnostics/start",Dict("session_id"=>owner,"action"=>"compile","target"=>"digest_string","mode"=>"graph"))
            @test started["started"]
            deadline=time()+15
            while isempty(server.approvals) && time()<deadline;sleep(0.01);end
            @test length(server.approvals)==1
            @test_throws ShenScopeError dispatch_rpc(server,"diagnostics/job",Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
            @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>owner,"prompt"=>"busy"))
            @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>owner,"title"=>"busy"))
            cancelled=dispatch_rpc(server,"diagnostics/cancel_job",Dict("session_id"=>owner,"job_id"=>started["job_id"]))
            deadline=time()+15;job=cancelled
            while job["status"]=="running" && time()<deadline
                sleep(0.01);job=dispatch_rpc(server,"diagnostics/job",Dict("session_id"=>owner,"job_id"=>started["job_id"]))
            end
            @test job["status"]=="cancelled"
            @test isempty(server.approvals)
            manager=ShenScope.server_diagnostics_tool(server).operations
            @test !ShenScope.operations_running(manager)
            stop_server!(server)
            @test manager.closed && isempty(manager.jobs)
        finally
            server.stopping || stop_server!(server)
        end
    end
end
