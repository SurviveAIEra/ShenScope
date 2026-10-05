function history_fixture(root;session_id="history-owner")
    ctx=project_testing_context(root;session_id);manager=ProjectTestManager()
    report=run_project_test_command!(manager,ctx;argv=["python3","-c","print(42)"],label="Small observed command")
    (;ctx,manager,report,store=project_test_history_store(ctx))
end

@testset "Saved test receipts retain observed evidence, ownership, revisions and current source" begin
    mktempdir() do root
        project_testing_fixture(root,"python");ctx=project_testing_context(root;session_id="history-python")
        manager=ProjectTestManager();catalog=discover_project_tests!(manager,ctx)
        report=run_project_tests!(manager,ctx;catalog_id=catalog["catalog_id"],candidate_id=only(catalog["candidates"])["id"])
        store=project_test_history_store(ctx);empty=list_project_test_history(store,ctx)
        @test empty["revision"]==0 && empty["total"]==0 && !ispath(store.directory)
        @test report["outcome"]=="command_failed"
        saved=save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=0,label="Before repair")
        @test saved["publication_committed"] && saved["changed"] && saved["revision"]==1
        @test saved["survives_server_restart"] && !saved["automatic_replay"]
        @test filesize(ShenScope.project_test_history_path(store))<store.limits.snapshot_bytes
        @test sort(readdir(store.directory))==["history.json","history.json.lock"]
        same=save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=1,label="Before repair")
        @test !same["changed"] && same["revision"]==1
        @test_throws ShenScopeError save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=0,label="Before repair")
        @test_throws ShenScopeError save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=1,label="Different label")
        renamed=label_project_test_history!(store,report["run_id"],"Python failure",ctx;expected_revision=1)
        @test renamed["revision"]==2 && renamed["action"]=="label"
        @test !label_project_test_history!(store,report["run_id"],"Python failure",ctx;expected_revision=2)["changed"]
        cleanup_project_tests!(manager)
        restarted=project_testing_context(root;session_id=ctx.session_id)
        loaded=read_project_test_history(project_test_history_store(restarted),report["run_id"],restarted)
        @test loaded["report"]==report && loaded["entry"]["label"]=="Python failure"
        @test isempty(manager.reports) && loaded["report"]["parsed"]["observed_case_counts"]["failed"]==1
        frame=first(report["parsed"]["frames"])
        preview=read_saved_project_test_source(store,report["run_id"],frame["id"],restarted)
        @test preview["saved_history_revision"]==2 && preview["report_sha256"]==report["sha256"]
        @test !preview["execution_source_snapshot_verified"] && preview["path"]==frame["path"]
        write(joinpath(root,frame["path"]),read(joinpath(root,frame["path"]),String)*"# changed\n")
        @test_throws ShenScopeError read_saved_project_test_source(store,report["run_id"],frame["id"],restarted;expected_sha256=preview["sha256"])
        @test read_project_test_history(store,report["run_id"],restarted)["report"]==report
        other=project_testing_context(root;session_id="other-history")
        @test list_project_test_history(project_test_history_store(other),other)["total"]==0
        @test_throws ShenScopeError read_project_test_history(store,report["run_id"],other)
        mktempdir() do foreign
            @test_throws ShenScopeError list_project_test_history(store,project_testing_context(foreign;session_id=ctx.session_id))
        end
        denied=project_testing_context(root;session_id=ctx.session_id);denied.permissions.rules[:read]=Deny
        @test_throws ShenScopeError read_project_test_history(store,report["run_id"],denied)
        denied.permissions.rules[:read]=Allow;denied.permissions.rules[:persistence]=Deny
        @test read_project_test_history(store,report["run_id"],denied)["report"]==report
        @test_throws ShenScopeError delete_project_test_history!(store,report["run_id"],denied;expected_revision=2)
        @test_throws ShenScopeError list_project_test_history(store,restarted;offset=true)
        @test_throws ShenScopeError list_project_test_history(store,restarted;expected_history_sha256=empty["history_sha256"])
        deleted=delete_project_test_history!(store,report["run_id"],restarted;expected_revision=2)
        @test deleted["revision"]==3 && list_project_test_history(store,restarted)["total"]==0
        @test_throws ShenScopeError read_project_test_history(store,report["run_id"],restarted)
        @test_throws ShenScopeError delete_project_test_history!(store,report["run_id"],restarted;expected_revision=3)
    end
end

@testset "Saved history rejects corrupt, foreign, unsupported and unsafe receipt content" begin
    mktempdir() do root
        fixture=history_fixture(root);(;ctx,manager,report,store)=fixture
        save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=0)
        path=ShenScope.project_test_history_path(store);original=read(path,String)
        for content in (original[1:end-1],original*" {}",replace(original,"\"revision\":1"=>"\"revision\":1,\"revision\":1"))
            write(path,content)
            @test_throws ShenScopeError list_project_test_history(store,ctx)
        end
        write(path,UInt8[0xff,0xfe]);@test_throws ShenScopeError list_project_test_history(store,ctx)
        for change! in (value->value["entries"][1]["report"]["process"]["stdout"]="tampered",
                value->value["owner"]["session_id"]="foreign",
                value->value["entries"][1]["report"]["automatic_replay"]=true,
                value->value["entries"][1]["report"]["parsed"]["complete_project_coverage"]=true)
            value=parsejson(original);change!(value);write(path,canonical(value))
            @test_throws ShenScopeError read_project_test_history(store,report["run_id"],ctx)
        end
        write(path,original)
        @test read_project_test_history(store,report["run_id"],ctx)["report"]==report
        copied=deepcopy(report);copied["run_id"]="another-observed-ID"
        @test_throws ShenScopeError ShenScope.project_test_history_report(copied,store,ctx)
        tool=TestingTool(manager,OperationManager(;event_prefix="testing"))
        with_agent_execution_mode(AgentPlan) do
            @test execute(tool,Dict("action"=>"history_get","run_id"=>report["run_id"]),ctx)["report"]==report
            @test "history_list" in ShenScope.plan_tool_actions(tool)
            @test !("history_save" in ShenScope.plan_tool_actions(tool))
            @test_throws ShenScopeError save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=1)
            @test_throws ShenScopeError label_project_test_history!(store,report["run_id"],"Denied in plan mode",ctx;expected_revision=1)
        end
    end
end

@testset "Saved history enforces count and serialized-byte capacity without retiring records" begin
    mktempdir() do root
        (;ctx,manager,report)=history_fixture(root)
        second=run_project_test_command!(manager,ctx;argv=["python3","-c","print(43)"],label="Second command")
        one=project_test_history_store(ctx;limits=ProjectTestHistoryLimits(;reports=1))
        save_project_test_history!(one,manager,report["run_id"],ctx;expected_revision=0)
        path=ShenScope.project_test_history_path(one);before=read(path,String)
        @test_throws ShenScopeError save_project_test_history!(one,manager,second["run_id"],ctx;expected_revision=1)
        @test read(path,String)==before && list_project_test_history(one,ctx)["total"]==1
        limited=project_test_history_store(ctx;limits=ProjectTestHistoryLimits(;report_bytes=4096,snapshot_bytes=4096))
        @test_throws ShenScopeError save_project_test_history!(limited,manager,second["run_id"],ctx;expected_revision=1)
        @test read(path,String)==before && !ispath(joinpath(one.directory,ShenScope.ATOMIC_STAGING_DIRECTORY))
        @test_throws ShenScopeError ProjectTestHistoryLimits(;reports=true)
        @test_throws ShenScopeError ProjectTestHistoryLimits(;reports=33)
        @test_throws ShenScopeError ProjectTestHistoryLimits(;report_bytes=8192,snapshot_bytes=4096)
        ctx.permissions.rules[:persistence]=Ask
        ctx.approve=request->begin;ctx.permissions.rules[:persistence]=Deny;:once;end
        @test_throws ShenScopeError delete_project_test_history!(one,report["run_id"],ctx;expected_revision=1)
        @test read(path,String)==before
        ctx.permissions.rules[:persistence]=Allow
        cancelled=child_context(ctx);cancel!(cancelled.cancellation,"Before save")
        @test_throws ShenScopeError delete_project_test_history!(one,report["run_id"],cancelled;expected_revision=1)
        @test read(path,String)==before
    end
end

@testset "Saved history refuses state symlinks and keeps raw control output bounded" begin
    mktempdir() do root
        (;ctx,manager,report,store)=history_fixture(root)
        mktempdir() do foreign
            mkpath(dirname(store.directory));symlink(foreign,store.directory)
            @test_throws ShenScopeError save_project_test_history!(store,manager,report["run_id"],ctx;expected_revision=0)
            @test isempty(readdir(foreign));rm(store.directory)
        end
        control=run_project_test_command!(manager,ctx;argv=["python3","-c","import sys;sys.stdout.write(chr(0)+chr(27)+chr(9))"],label="Control output")
        save_project_test_history!(store,manager,control["run_id"],ctx;expected_revision=0)
        @test read_project_test_history(store,control["run_id"],ctx)["report"]["process"]["stdout"]=="\0\e\t"
        path=ShenScope.project_test_history_path(store);before=read(path,String)
        rm(path*".lock");symlink(joinpath(root,"foreign.lock"),path*".lock")
        @test_throws ShenScopeError delete_project_test_history!(store,control["run_id"],ctx;expected_revision=1)
        @test read(path,String)==before && !ispath(joinpath(root,"foreign.lock"))
    end
end
