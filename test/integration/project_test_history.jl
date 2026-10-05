@testset "Two Julia processes fence saved-history edits with the same expected revision" begin
    mktempdir() do root
        (;ctx,manager,report,store)=history_fixture(root)
        save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=0)
        gate=joinpath(root,"start-gate")
        script=joinpath(@__DIR__,"../fixtures/project_test_history_worker.jl")
        command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(dirname(@__DIR__))) $script`
        processes=Base.Process[]
        for worker in ("worker-one","worker-two")
            push!(processes,run(pipeline(ignorestatus(`$command $root $(ctx.session_id) $(report["run_id"]) $worker $gate`);
                stdout=joinpath(root,worker*".out"),stderr=joinpath(root,worker*".err"));wait=false))
        end
        ready=timedwait(()->all(isfile(joinpath(root,worker*".ready")) for worker in ("worker-one","worker-two")),180;pollint=0.05)
        @test ready==:ok
        write(gate,"go\n");foreach(wait,processes)
        @test all(process->process.exitcode==0,processes)
        outcomes=[strip(read(joinpath(root,worker*".out"),String)) for worker in ("worker-one","worker-two")]
        @test sort(outcomes)==["changed","conflict"]
        value=read_project_test_history(store,report["run_id"],ctx)
        @test value["revision"]==2 && value["entry"]["label"] in ("worker-one","worker-two")
        @test value["report"]==report && sort(readdir(store.directory))==["history.json","history.json.lock"]
    end
end

@testset "CLI saves failed test receipts and reads them independently of process permission" begin
    mktempdir() do root
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\nprocess='deny'\npersistence='deny'\nnetwork='deny'\n")
        common=["--root",root,"--state-dir",joinpath(root,"state"),"--config",config,"--session","cli-history"]
        function invoke(arguments)
            path=joinpath(root,"cli-result.json")
            status=open(path,"w") do output
                redirect_stdout(output) do;ShenScope.main(vcat(["tests"],arguments,common));end
            end
            status,parsejson(read(path,String))
        end
        status,saved=invoke(["custom","--argv","[\"python3\",\"-c\",\"raise SystemExit(1)\"]","--allow-process","--allow-persistence","--save","--expected-revision","0"])
        @test status==1 && saved["report"]["outcome"]=="command_failed" && saved["saved"]["revision"]==1
        id=saved["report"]["run_id"]
        status,loaded=invoke(["show",id]);@test status==0 && loaded["report"]==saved["report"]
        status,list=invoke(["saved"]);@test status==0 && list["total"]==1
        status,renamed=invoke(["rename",id,"--title","Failed before repair","--expected-revision","1","--allow-persistence"])
        @test status==0 && renamed["revision"]==2
        status,not_saved=invoke(["custom","--argv","[\"python3\",\"-c\",\"print(42)\"]","--allow-process","--save","--expected-revision","2"])
        @test status==2 && not_saved["report"]["exit_code"]==0 && not_saved["saved"]===nothing && not_saved["save_error"]["code"]=="permission"
        status,list=invoke(["saved"]);@test status==0 && list["total"]==1 && list["revision"]==2
        status,deleted=invoke(["forget",id,"--expected-revision","2","--allow-persistence"])
        @test status==0 && deleted["total"]==0 && deleted["revision"]==3
    end
end

@testset "Post-publication cancellation and sink failure preserve owned commit evidence" begin
    mktempdir() do root
        (;ctx,manager,report,store)=history_fixture(root)
        operations=OperationManager(;event_prefix="testing")
        ctx.sink=event->begin
            if event.kind==:testing_history_committed
                cancel!(ShenScope.current_context().cancellation,"Cancelled after durable publication")
                error("Disconnected notification sink")
            end
        end
        job=start_operation!(operations,ctx;kind="history_save") do child
            save_project_test_history!(project_test_history_store(child),manager,report["run_id"],child;expected_revision=0)
        end
        @test timedwait(()->ShenScope.owned_operation(operations,job["job_id"],ctx)["status"]!="running",30;pollint=0.025)==:ok
        view=ShenScope.owned_operation(operations,job["job_id"],ctx)
        @test view["status"]=="cancelled" && view["result"]===nothing
        commit=only(view["committed_effects"])
        @test commit["kind"]=="testing.history" && commit["revision"]==1 && commit["run_id"]==report["run_id"]
        @test read_project_test_history(store,report["run_id"],ctx)["report"]==report
        @test list_project_test_history(store,ctx)["history_sha256"]==commit["history_sha256"]
        @test length(manager.reports)==1
        close_operations!(operations)
    end
end

@testset "Saved-history RPC permissions, controller reads and late delivery fencing" begin
    mktempdir() do root
        config=joinpath(root,"config.toml");write(config,"[permissions]\nread='allow'\nprocess='allow'\npersistence='ask'\nnetwork='deny'\n")
        server=CoreServer(root;state_dir=joinpath(root,"state"),config_file=config,output=IOBuffer())
        try
            @test dispatch_rpc(server,"initialize",Dict())["capabilities"]["project_testing"]["saved_history_survives_restart"]
            owner=dispatch_rpc(server,"sessions/create",Dict())["id"];other=dispatch_rpc(server,"sessions/create",Dict())["id"]
            started=dispatch_rpc(server,"testing/start",Dict("session_id"=>owner,"action"=>"custom","argv"=>["python3","-c","print(42)"]))
            run=project_testing_job(server,owner,started["job_id"])["result"]
            save=dispatch_rpc(server,"testing/start",Dict("session_id"=>owner,"action"=>"history_save","run_id"=>run["run_id"],"expected_revision"=>0))
            @test timedwait(()->!isempty(server.approvals),10;pollint=0.025)==:ok
            @test dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"history_list"))["total"]==0
            request=only(keys(server.approvals))
            @test_throws ShenScopeError dispatch_rpc(server,"permissions/respond",Dict("session_id"=>other,"request_id"=>request,"decision"=>"once"))
            dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>request,"decision"=>"once"))
            finished=project_testing_job(server,owner,save["job_id"])
            @test finished["status"]=="complete" && only(finished["committed_effects"])["kind"]=="testing.history"
            cleanup_project_tests!(ShenScope.server_testing_tool(server).manager)
            loaded=dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"history_get","run_id"=>run["run_id"]))
            @test loaded["report"]==run && !loaded["automatic_replay"]
            @test_throws ShenScopeError dispatch_rpc(server,"testing/query",Dict("session_id"=>other,"action"=>"history_get","run_id"=>run["run_id"]))
            @test_throws RPCFault dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"history_delete","run_id"=>run["run_id"],"expected_revision"=>1))
            server.contexts[owner].permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"testing/job",Dict("session_id"=>owner,"job_id"=>save["job_id"]))
            @test hidden["result"]===nothing && isempty(hidden["committed_effects"]) && hidden["commit_evidence_hidden_by_permission"]
            event=AgentEvent(1,:testing_history_committed,owner,"fixture",ShenScope.utcstamp(),only(finished["committed_effects"]))
            @test ShenScope.testing_event_payload(server,event,event.payload)==Dict("evidence_hidden_by_permission"=>true)
            server.contexts[owner].permissions.rules[:read]=Ask
            @test_throws ShenScopeError dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"history_list"))
            @test isempty(server.approvals)
            server.contexts[owner].permissions.rules[:read]=Allow
            @test dispatch_rpc(server,"testing/query",Dict("session_id"=>owner,"action"=>"history_list"))["total"]==1
        finally;stop_server!(server);end
    end
end
