using ShenScope, Test
include("helpers.jl")

function workflow_server(root)
    CoreServer(root; state_dir=joinpath(root,"state"), config_file=joinpath(root,"config.toml"), output=IOBuffer())
end

@testset "Language, workspace and validation jobs keep ownership, busy guards and pending-approval cancellation" begin
    for prefix in ("language", "workspace", "validation")
        mktempdir() do root
            write(joinpath(root,"sample.py"), "old\n")
            server = workflow_server(root)
            try
                dispatch_rpc(server,"initialize",Dict())
                sid = dispatch_rpc(server,"sessions/create",Dict())["id"]
                foreign = dispatch_rpc(server,"sessions/create",Dict())["id"]
                ctx = ShenScope.server_context(server,sid)
                ctx.permissions.rules[:read] = Allow
                ctx.permissions.rules[:process] = Ask
                ctx.permissions.rules[:edit] = Ask
                arguments = if prefix == "language"
                    Dict("action"=>"start", "name"=>"pending", "argv"=>[Sys.which("python3"),"-c","print('not an LSP server')"],
                        "languages"=>["python"])
                elseif prefix == "validation"
                    Dict("action"=>"run", "argv"=>[Sys.which("python3"),"-c","print('sample.py:1:1: error: fixture')"],
                        "paths"=>["sample.py"])
                else
                    file = Dict("path"=>"sample.py", "expected_sha256"=>digest("old\n"),
                        "edits"=>[Dict("location"=>Dict("file"=>"sample.py","start_line"=>1,"end_line"=>1,
                            "start_column"=>1,"end_column"=>4), "new_text"=>"new")])
                    plan = prepare_workspace_edits!(ShenScope.server_workspace_tool(server).manager, ctx, [file])
                    Dict("action"=>"apply", "plan_id"=>plan["plan_id"], "expected_plan_sha256"=>plan["plan_sha256"])
                end
                started = dispatch_rpc(server,prefix*"/start",merge(arguments,Dict("session_id"=>sid)))
                @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
                config = dispatch_rpc(server,"config/get",Dict())
                @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("value"=>config["value"],"expected_sha256"=>config["sha256"]))
                @test_throws ShenScopeError dispatch_rpc(server,"sessions/rename",Dict("session_id"=>sid,"title"=>"busy"))
                @test_throws ShenScopeError dispatch_rpc(server,"agent/start",Dict("session_id"=>sid,"prompt"=>"busy"))
                for action in ("job", "cancel")
                    @test_throws ShenScopeError dispatch_rpc(server,prefix*"/"*action,Dict("session_id"=>foreign,"job_id"=>started["job_id"]))
                end
                dispatch_rpc(server,prefix*"/cancel",Dict("session_id"=>sid,"job_id"=>started["job_id"]))
                @test timedwait(()->isempty(server.approvals),10;pollint=0.01)==:ok
                poll() = dispatch_rpc(server,prefix*"/job",Dict("session_id"=>sid,"job_id"=>started["job_id"]))
                @test timedwait(()->poll()["status"]!="running",10;pollint=0.01)==:ok
                @test !iscancelled(ctx.cancellation) && read(joinpath(root,"sample.py"),String)=="old\n"
                ctx.permissions.rules[:read] = Deny
                @test poll()["result"] === nothing
                query = Dict("session_id"=>sid,"action"=>prefix=="language" ? "status" : "list")
                @test_throws ShenScopeError dispatch_rpc(server,prefix*"/query",query)
            finally
                stop_server!(server)
            end
        end
    end
end

@testset "Server shutdown drains validation before closing shared managers" begin
    mktempdir() do root
        write(joinpath(root,"sample.py"),"value = 1\n")
        server=workflow_server(root)
        dispatch_rpc(server,"initialize",Dict())
        sid=dispatch_rpc(server,"sessions/create",Dict())["id"]
        ctx=ShenScope.server_context(server,sid)
        ctx.permissions.rules[:read]=Allow
        ctx.permissions.rules[:process]=Ask
        started=dispatch_rpc(server,"validation/start",Dict("session_id"=>sid,"action"=>"run",
            "argv"=>[Sys.which("python3"),"-c","print('never started')"],"paths"=>["sample.py"]))
        @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
        stopped=@async stop_server!(server)
        @test timedwait(()->istaskdone(stopped),10;pollint=0.01)==:ok
        fetch(stopped)
        @test isempty(server.approvals)
        @test !ShenScope.operations_running(ShenScope.server_validation_tool(server).operations)
        @test !iscancelled(ctx.cancellation)
    end
end
