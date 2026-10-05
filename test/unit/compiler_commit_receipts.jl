@testset "Published compiler catalogs survive notification failures and interrupted owned completion" begin
    mktempdir() do root
        owner=compiler_archive_context(root);store=compiler_archive_store(owner)
        fixture=compiler_archive_recorded_fixture()
        id=compiler_archive_install_fixture!(store,owner,fixture.result,fixture.source)
        manager=ShenScope.OperationManager(;event_prefix="diagnostics")
        try
            owner.sink=event->event.kind==:compiler_archive_committed && error("Transport closed")
            started=ShenScope.start_operation!(manager,owner;kind="archive_label") do ctx
                compiler_archive_label(store,id,"Committed despite notification",ctx;expected_revision=1)
            end
            job=await_owned_operation(manager,started["job_id"]);wait(job.task)
            @test job.status==:complete && job.result["commit_notification_failed"]
            @test length(job.committed_effects)==1 && job.committed_effects[1]["revision"]==2
            @test compiler_archive_list(store,owner)["items"][1]["title"]=="Committed despite notification"
            owner.sink=event->event.kind==:compiler_archive_committed && cancel!(current_context().cancellation,"Interrupt after atomic publication")
            interrupted=ShenScope.start_operation!(manager,owner;kind="archive_label") do ctx
                compiler_archive_label(store,id,"Committed before cancellation",ctx;expected_revision=2)
            end
            cancelled=await_owned_operation(manager,interrupted["job_id"]);wait(cancelled.task)
            @test cancelled.status==:cancelled && !iscancelled(owner.cancellation)
            @test only(cancelled.committed_effects)["revision"]==3
            @test compiler_archive_list(store,owner)["items"][1]["title"]=="Committed before cancellation"
            owner.sink=event->begin
                if event.kind==:compiler_archive_committed
                    owner.budget.started_ns-=UInt64(4_000_000_000_000)
                end
                nothing
            end
            expired=ShenScope.start_operation!(manager,owner;kind="archive_label") do ctx
                compiler_archive_label(store,id,"Committed before budget expiry",ctx;expected_revision=3)
            end
            failed=await_owned_operation(manager,expired["job_id"]);wait(failed.task)
            @test failed.status==:failed && failed.error_code==:budget
            @test only(failed.committed_effects)["revision"]==4
            fresh=compiler_archive_context(root)
            @test compiler_archive_list(store,fresh)["items"][1]["title"]=="Committed before budget expiry"
            @test owned_operation(manager,failed.id,fresh)["committed_effects"][1]["session_id"]==fresh.session_id
        finally
            ShenScope.close_operations!(manager)
        end
    end
end

@testset "Read denial after publication hides result bodies and commit receipts on both RPC paths" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\npersistence='allow'\nprocess='deny'\ndynamic='deny'\nnetwork='deny'\n")
        output=IOBuffer();server=CoreServer(root;config_file=config,state_dir=joinpath(root,"state"),output)
        try
            dispatch_rpc(server,"initialize",Dict())
            id=dispatch_rpc(server,"sessions/create",Dict())["id"]
            owner=ShenScope.server_context(server,id);ctx=compiler_archive_context(root;session_id=id)
            store=compiler_archive_store(ctx);fixture=compiler_archive_recorded_fixture()
            report_id=compiler_archive_install_fixture!(store,ctx,fixture.result,fixture.source)
            original=owner.sink
            owner.sink=event->begin
                event.kind==:compiler_archive_committed && (owner.permissions.rules[:read]=Deny)
                original(event)
            end
            started=dispatch_rpc(server,"diagnostics/start",Dict("session_id"=>id,"action"=>"archive_label",
                "report_id"=>report_id,"title"=>"Published before Read denial","expected_revision"=>1))
            manager=ShenScope.server_diagnostics_tool(server).operations
            job=await_owned_operation(manager,started["job_id"]);wait(job.task)
            @test job.status==:failed && job.error_code==:permission
            @test only(job.committed_effects)["revision"]==2
            poll=dispatch_rpc(server,"diagnostics/job",Dict("session_id"=>id,"job_id"=>job.id))
            @test poll["result"]===nothing && isempty(poll["committed_effects"])
            seekstart(output);notifications=Any[]
            while !eof(output);push!(notifications,read_rpc(output));end
            finished=only(message for message in notifications if message["params"]["kind"]=="diagnostics_job_failed")
            @test finished["params"]["payload"]["result"]===nothing
            @test isempty(finished["params"]["payload"]["committed_effects"])
            commit=only(message for message in notifications if message["params"]["kind"]=="compiler_archive_committed")
            @test commit["params"]["payload"]==Dict("evidence_hidden_by_permission"=>true)
            @test compiler_archive_list(store,ctx)["items"][1]["title"]=="Published before Read denial"
        finally
            stop_server!(server)
        end
    end
end

@testset "Owned archive reads retain valid evidence exceeding the former two MiB result cap" begin
    mktempdir() do root
        config=joinpath(root,"config.toml")
        write(config,"[permissions]\nread='allow'\nprocess='deny'\ndynamic='deny'\npersistence='allow'\nnetwork='deny'\n")
        output=IOBuffer();server=CoreServer(root;config_file=config,state_dir=joinpath(root,"state"),output)
        try
            dispatch_rpc(server,"initialize",Dict())
            id=dispatch_rpc(server,"sessions/create",Dict())["id"]
            ctx=compiler_archive_context(root;session_id=id);store=compiler_archive_store(ctx)
            fixture=compiler_archive_recorded_fixture();source=deepcopy(fixture.source)
            # Synthetic unsigned inventory metadata exercises the real archive,
            # owned-manager and framed RPC path; no source folders are created.
            segment=repeat("nested",32)
            for number in 1:700
                path="src/"*join(fill(segment,16),'/')*"/fixture-"*string(number)*".jl"
                push!(source["files"],Dict("path"=>path,"bytes"=>1,"sha256"=>digest("fixture-"*string(number))))
            end
            sort!(source["files"];by=row->row["path"])
            source["fingerprint"]=digest(canonical(Dict(k=>v for (k,v) in source if k!="fingerprint")))
            result=deepcopy(fixture.result);result["report"]["source"]["fingerprint"]=source["fingerprint"]
            compiler_fixture_rehash!(result["report"])
            report_id=compiler_archive_install_fixture!(store,ctx,result,source;title="Large unsigned inventory fixture")
            started=dispatch_rpc(server,"diagnostics/start",Dict("session_id"=>id,"action"=>"archive_get","report_id"=>report_id))
            manager=ShenScope.server_diagnostics_tool(server).operations
            job=await_owned_operation(manager,started["job_id"];timeout=60);wait(job.task)
            @test job.status==:complete
            @test 2*1024^2+4096<job.result_bytes<3*1024^2+4096
            @test job.result["report"]==result["report"] && !job.result["producer_authenticated"]
            seekstart(output);notification=read_rpc(output)
            @test notification["params"]["kind"]=="diagnostics_job_completed"
            @test notification["params"]["payload"]["result"]["report"]["report_sha256"]==report_id
            server.contexts[id].permissions.rules[:read]=Deny
            hidden=dispatch_rpc(server,"diagnostics/job",Dict("session_id"=>id,"job_id"=>job.id))
            @test hidden["result"]===nothing && hidden["result_hidden_by_permission"]
            @test isempty(hidden["committed_effects"]) && hidden["commit_evidence_hidden_by_permission"]
        finally
            stop_server!(server)
        end
    end
end
