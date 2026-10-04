@testset "Watch RPC owns conversations, excludes manual mutations and drains independently" begin
    mktempdir() do root
        write(joinpath(root,"main.go"),"package watched\nfunc F() int { return 0 }\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=joinpath(root,"config.toml"),output=IOBuffer())
        try
            dispatch_rpc(server,"initialize",Dict("protocol_version"=>PROTOCOL_VERSION))
            id=dispatch_rpc(server,"sessions/create",Dict("title"=>"Index changes"))["id"]
            foreign=dispatch_rpc(server,"sessions/create",Dict("title"=>"Other"))["id"]
            @test_throws ShenScopeError dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast"))
            job=dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"go_ast","action"=>"build"))["job_id"]
            answered=Set{String}();deadline=time()+30
            while dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))["status"]=="running" && time()<deadline
                for request in collect(keys(server.approvals))
                    request in answered && continue
                    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"session"))
                    push!(answered,request)
                end
                sleep(0.01)
            end
            @test dispatch_rpc(server,"project/job",Dict("session_id"=>id,"job_id"=>job))["status"]=="complete"
            watch=dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast","poll_seconds"=>0.05,"quiet_seconds"=>0.02))
            params=Dict("session_id"=>id,"watch_id"=>watch["id"])
            @test watch["automatic"]==false && watch["phase"]=="starting"
            @test timedwait(()->dispatch_rpc(server,"project/watch_status",params)["scans"]>0,10)==:ok
            for method in ("project/watch_status","project/watch_stop","project/watch_refresh")
                @test_throws ShenScopeError dispatch_rpc(server,method,merge(params,Dict("session_id"=>foreign)))
            end
            @test dispatch_rpc(server,"project/watch_list",Dict("session_id"=>foreign))==[]
            @test length(dispatch_rpc(server,"project/watch_list",Dict("session_id"=>id)))==1
            @test_throws ShenScopeError dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast"))
            @test_throws RPCFault dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast","unexpected"=>true))
            @test_throws ShenScopeError dispatch_rpc(server,"project/start",Dict("session_id"=>id,"backend"=>"go_ast","action"=>"build"))
            config=dispatch_rpc(server,"config/get",Dict())
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("expected_sha256"=>config["sha256"],"value"=>config["value"]))
            manager=ShenScope.server_project_tool(server).manager;owner=server.contexts[id]
            @test_throws ShenScopeError ShenScope.execute(ShenScope.server_project_tool(server),Dict("action"=>"compact","backend"=>"go_ast"),owner)
            @test isempty(manager.mutations)
            key=ShenScope.digest(server.root)*":go_ast";state=manager.states[key];revision=state.revision
            write(joinpath(root,"main.go"),"package watched\nfunc F() int { return 1 }\n")
            @test timedwait(()->dispatch_rpc(server,"project/watch_status",params)["phase"]=="dirty",10)==:ok
            @test state.revision==revision && dispatch_rpc(server,"project/query",Dict("session_id"=>id,"backend"=>"go_ast"))["revision"]==revision
            @test dispatch_rpc(server,"project/watch_refresh",params)["refresh_requested"]
            @test timedwait(()->dispatch_rpc(server,"project/watch_status",params)["updates"]==1,10)==:ok
            @test state.revision==revision+1
            @test_throws ShenScopeError dispatch_rpc(server,"project/watch_status",merge(params,Dict("offset"=>-1)))
            @test_throws RPCFault dispatch_rpc(server,"project/watch_stop",merge(params,Dict("extra"=>true)))
            @test dispatch_rpc(server,"project/watch_stop",params)["phase"]=="stopping"
            watcher=manager.watches[watch["id"]]
            @test timedwait(()->istaskdone(watcher.task),10)==:ok
            @test dispatch_rpc(server,"project/watch_status",params)["phase"]=="stopped"
            @test !iscancelled(owner.cancellation) && isempty(server.approvals)
            @test_throws ShenScopeError dispatch_rpc(server,"project/watch_refresh",params)
            owner.permissions.rules[:persistence]=Ask;empty!(owner.permissions.grants)
            context=ShenScope.child_context(owner)
            context.approve=request->ShenScope.server_approval(server,id,context.cancellation,request)
            manual=@async try
                ShenScope.with_context(()->ShenScope.execute(ShenScope.server_project_tool(server),Dict("action"=>"compact","backend"=>"go_ast"),context),context)
                nothing
            catch error;error;end
            @test timedwait(()->!isempty(server.approvals),10)==:ok
            @test_throws ShenScopeError dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast"))
            @test_throws ShenScopeError dispatch_rpc(server,"config/set",Dict("expected_sha256"=>config["sha256"],"value"=>config["value"]))
            owner.permissions.rules[:persistence]=Deny
            request=only(keys(server.approvals))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>id,"request_id"=>request,"decision"=>"once"))
            @test timedwait(()->istaskdone(manual),10)==:ok
            @test fetch(manual) isa ShenScopeError && isempty(manager.mutations) && isempty(server.approvals)
            owner.permissions.rules[:persistence]=Ask
            # A pending child approval must drain on stop without cancelling its owner.
            owner.permissions.rules[:read]=Ask;empty!(owner.permissions.grants)
            pending=dispatch_rpc(server,"project/watch_start",Dict("session_id"=>id,"backend"=>"go_ast","native_hints"=>false))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.01)==:ok
            dispatch_rpc(server,"project/watch_stop",Dict("session_id"=>id,"watch_id"=>pending["id"]))
            @test timedwait(()->istaskdone(manager.watches[pending["id"]].task),5)==:ok
            @test isempty(server.approvals) && !iscancelled(owner.cancellation)
            owner.permissions.rules[:read]=Allow
            @test isempty(manager.mutations)
        finally
            stop_server!(server)
        end
    end
end
