@testset "Actual compiler reports archive atomically, preserve ownership and use catalog CAS" begin
    mktempdir() do root
        ctx=compiler_archive_context(root);store=compiler_archive_store(ctx)
        empty=compiler_archive_list(store,ctx)
        @test empty["revision"]==0 && empty["total"]==0 && !ispath(store.directory)
        result=run_compiler_diagnostic(ctx,"cliptext_string";mode="graph",timeout=120)
        saved=compiler_archive_save(store,result,ctx;expected_revision=0,title="UTF-8 inference 中文")
        id=result["report"]["report_sha256"]
        @test saved["revision"]==1 && !saved["already_saved"]
        @test saved["entry"]["report_sha256"]==id
        catalog=compiler_archive_list(store,ctx;limit=1)
        @test catalog["total"]==1 && catalog["next_offset"]===nothing && catalog["orphan_assets"]==0
        @test catalog["items"][1]["title"]=="UTF-8 inference 中文"
        @test catalog["staging_bytes"]==0 && catalog["asset_bytes"]>0
        loaded=compiler_archive_get(store,id,ctx;expected_index_sha256=catalog["index_sha256"])
        @test loaded["report"]==result["report"] && loaded["execution"]==result["execution"]
        @test loaded["integrity_checked"] && loaded["source_currentness"]=="not_checked" && !loaded["producer_authenticated"]
        @test compiler_archive_save(store,result,ctx;expected_revision=1)["already_saved"]
        @test compiler_archive_list(store,ctx)["revision"]==1
        @test_throws ShenScopeError compiler_archive_save(store,result,ctx;expected_revision=0)
        foreign=compiler_archive_context(root;session_id="another-owner")
        @test_throws ShenScopeError compiler_archive_get(store,id,foreign)
        @test compiler_archive_list(compiler_archive_store(foreign),foreign)["total"]==0
        labelled=compiler_archive_label(store,id,"Reviewed",ctx;expected_revision=1)
        @test labelled["revision"]==2 && labelled["changed"]
        @test !compiler_archive_label(store,id,"Reviewed",ctx;expected_revision=2)["changed"]
        @test_throws ShenScopeError compiler_archive_list(store,ctx;expected_index_sha256=catalog["index_sha256"])
        @test_throws ShenScopeError compiler_archive_get(store,id,ctx;expected_index_sha256=catalog["index_sha256"])
        identity=compiler_archive_compare(store,id,id,ctx)
        @test identity["comparable"] && identity["changes_total"]==0 && !identity["performance_change_proven"]
        @test all(row->row["uniquely_source_anchored_pairs"]+row["unpaired_statements_before"]==length(result["report"]["methods"][1]["statements"]),identity["methods"])
        @test !identity["behavior_equivalence_proven"]
        @test compiler_archive_list(store,ctx;offset=100)["items"]==Any[]
        @test_throws ShenScopeError compiler_archive_list(store,ctx;limit=true)
        @test_throws ShenScopeError compiler_archive_compare(store,id,id,ctx;limit=0)
        @test_throws ShenScopeError CompilerArchiveLimits(;max_reports=true)
        @test_throws ShenScopeError CompilerArchiveLimits(;max_total_bytes=1023)
        denied=RuntimeContext(root;session_id=ctx.session_id,state_dir=ctx.state_dir,
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Deny)))
        @test_throws ShenScopeError compiler_archive_delete(store,id,denied;expected_revision=2)
        @test compiler_archive_list(store,ctx)["revision"]==2
        changed_execution=deepcopy(result);changed_execution["execution"]["timeout_seconds"]=119
        @test_throws ShenScopeError compiler_archive_save(store,changed_execution,ctx;expected_revision=2)
        deleted=compiler_archive_delete(store,id,ctx;expected_revision=2)
        @test deleted["revision"]==3 && isfile(joinpath(store.directory,id*".json"))
        @test_throws ShenScopeError compiler_archive_get(store,id,ctx)
        plan=compiler_archive_gc(store,ctx)
        @test plan["dry_run"] && length(plan["items"])==1 && plan["reclaimable_bytes"]==catalog["asset_bytes"]
        @test_throws ShenScopeError compiler_archive_gc(store,ctx;dry_run=false)
        cleanup=compiler_archive_gc(store,ctx;dry_run=false,expected_revision=3)
        @test cleanup["removed_assets"]==1 && !isfile(joinpath(store.directory,id*".json"))
        @test compiler_archive_list(store,ctx)["asset_bytes"]==0
    end
end

@testset "Recorded compiler source inventory survives Core changes and refuses rehashed malformed evidence" begin
    fixture=compiler_archive_recorded_fixture()
    mktempdir() do root
        ctx=compiler_archive_context(root);store=compiler_archive_store(ctx)
        id=compiler_archive_install_fixture!(store,ctx,fixture.result,fixture.source)
        loaded=compiler_archive_get(store,id,ctx)
        @test loaded["report"]["source"]["fingerprint"]==fixture.source["fingerprint"]
        current=runtime_source_snapshot(ctx)
        @test current.fingerprint!=fixture.source["fingerprint"]
        @test_throws ShenScopeError ShenScope.compiler_ir_validate_report(fixture.result["report"],
            ShenScope.compiler_target("cliptext_string"),current)
        changed=deepcopy(fixture.result)
        changed["report"]["methods"][1]["return_type"]=Dict("type"=>"Any","classification"=>"any",
            "concrete"=>false,"bottom"=>false,"constant_value_exposed"=>false)
        changed["report"]["effects"]["proven_properties"]["nothrow"]=true
        compiler_fixture_rehash!(changed["report"])
        changed_id=compiler_archive_install_fixture!(store,ctx,changed,fixture.source;title="Synthetic observation comparison")
        compared=compiler_archive_compare(store,id,changed_id,ctx;limit=1)
        @test compared["comparable"] && compared["changes_total"]==2 && compared["changes_truncated"] && length(compared["changes"])==1
        @test compared["changes"][1]["kind"]=="return_type_changed"
        @test !compared["source_changed"] && !compared["producer_authenticated"]
        other_version=deepcopy(fixture.result);other_version["report"]["runtime"]["julia_version"]="1.11.6"
        other_version["report"]["effects"]["julia_version"]="1.11.6"
        compiler_fixture_rehash!(other_version["report"])
        version_id=compiler_archive_install_fixture!(store,ctx,other_version,fixture.source)
        incompatible=compiler_archive_compare(store,id,version_id,ctx)
        @test !incompatible["comparable"] && "julia_version_changed" in incompatible["reasons"]
        paged=compiler_archive_list(store,ctx;limit=1)
        @test paged["total"]==3 && paged["next_offset"]==1
        next=compiler_archive_list(store,ctx;offset=1,limit=1,expected_index_sha256=paged["index_sha256"])
        @test next["items"][1]["report_sha256"]!=paged["items"][1]["report_sha256"]
        @test compiler_archive_list(store,ctx;target="digest_string")["total"]==0
        asset_path=joinpath(store.directory,id*".json");original=read(asset_path,String)
        write(asset_path,original*" ")
        @test_throws ShenScopeError compiler_archive_get(store,id,ctx)
        write(asset_path,original)
        index_path=joinpath(store.directory,"index.json");original_index=read(index_path,String)
        index=parsejson(original_index);index["owner"]["session_id"]="another-owner"
        index["index_sha256"]=digest(canonical(Dict(k=>v for (k,v) in index if k!="index_sha256")))
        write(index_path,canonical(index))
        @test_throws ShenScopeError compiler_archive_list(store,ctx)
        write(index_path,original_index)
        snapshot=ShenScope.runtime_source_from_view(fixture.source)
        for change in (report->(report["methods"][1]["control_flow"]["blocks"][1]["successors"]=[999]),
                report->(report["methods"][1]["identity"]["file"]="src/../escape.jl"),
                report->(report["runtime"]["machine"]="../machine"),
                report->(report["effects"]["safety_boundary"]=true))
            corrupted=deepcopy(fixture.result["report"]);change(corrupted);compiler_fixture_rehash!(corrupted)
            @test_throws ShenScopeError ShenScope.compiler_ir_validate_report(corrupted,
                ShenScope.compiler_target("cliptext_string"),snapshot;historical=true)
        end
        if Sys.isunix()
            rm(asset_path);symlink(joinpath(root,"external"),asset_path)
            @test_throws ShenScopeError compiler_archive_get(store,id,ctx)
        end
    end
end

@testset "Two real Julia processes cannot both commit the same compiler catalog revision" begin
    mktempdir() do root
        ctx=compiler_archive_context(root);store=compiler_archive_store(ctx)
        fixture=compiler_archive_recorded_fixture()
        id=compiler_archive_install_fixture!(store,ctx,fixture.result,fixture.source)
        project=ShenScope.runtime_core_root();gate=joinpath(root,"start-gate")
        code="""
        using ShenScope
        ctx=RuntimeContext(ARGS[1];session_id=ARGS[2],state_dir=joinpath(ARGS[1],"state"),
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow)))
        deadline=time()+30
        while !isfile(ARGS[3]) && time()<deadline;sleep(0.01);end
        isfile(ARGS[3]) || error("Fixture gate deadline")
        result=try
            value=compiler_archive_label(compiler_archive_store(ctx),ARGS[4],ARGS[5],ctx;expected_revision=1)
            Dict("status"=>"committed","revision"=>value["revision"])
        catch cause
            cause isa ShenScopeError || rethrow()
            Dict("status"=>"refused","code"=>String(cause.code))
        end
        println(canonical(result))
        """
        processes=Base.Process[];outputs=IOStream[];paths=String[]
        try
            for label in ("Process A","Process B")
                path=joinpath(root,label*".json");output=open(path,"w")
                push!(outputs,output);push!(paths,path)
                command=Cmd([first(Base.julia_cmd().exec),"--startup-file=no","--compiled-modules=existing",
                    "--threads=1","--project="*project,"-e",code,root,ctx.session_id,gate,id,label])
                push!(processes,run(pipeline(command;stdout=output);wait=false))
            end
            write(gate,"start")
            for process in processes;wait(process);@test success(process);end
            for output in outputs;close(output);end
            results=[parsejson(read(path,String)) for path in paths]
            @test count(row->row["status"]=="committed",results)==1
            @test count(row->row["status"]=="refused" && row["code"]=="conflict",results)==1
            catalog=compiler_archive_list(store,ctx)
            @test catalog["revision"]==2 && catalog["items"][1]["title"] in ("Process A","Process B")
            @test compiler_archive_get(store,id,ctx)["report"]==fixture.result["report"]
        finally
            for process in processes;process_exited(process) || kill(process);wait(process);end
            for output in outputs;isopen(output) && close(output);end
        end
    end
end

@testset "Compiler archive cancellation leaves reviewable orphans and retains referenced evidence" begin
    mktempdir() do root
        approvals=Symbol[]
        ctx=compiler_archive_context(root;sink=event->nothing)
        # The actual current report is generated through compiler inference;
        # this unit boundary does not claim a separately executed helper.
        report=compiler_ir_report("digest_string")
        result=Dict("report"=>report,"execution"=>Dict("separate_process"=>true,"os_sandbox"=>false,"timeout_seconds"=>60.0))
        store=compiler_archive_store(ctx)
        ctx.sink=event->event.kind==:compiler_archive_asset_saved && cancel!(ctx.cancellation,"Cancel before catalog commit")
        @test_throws ShenScopeError compiler_archive_save(store,result,ctx;expected_revision=0)
        fresh=compiler_archive_context(root)
        catalog=compiler_archive_list(store,fresh)
        @test catalog["revision"]==0 && catalog["total"]==0 && catalog["orphan_assets"]==1
        @test compiler_archive_gc(store,fresh)["reclaimable_bytes"]>0
        @test compiler_archive_save(store,result,fresh;expected_revision=0)["revision"]==1
        @test compiler_archive_gc(store,fresh;dry_run=false,expected_revision=1)["removed_assets"]==0
        restricted=compiler_archive_store(fresh;limits=CompilerArchiveLimits(;max_reports=1,max_total_bytes=1024))
        @test_throws ShenScopeError compiler_archive_list(restricted,fresh)
        readonly=RuntimeContext(root;session_id=fresh.session_id,state_dir=fresh.state_dir,
            permissions=PermissionPolicy(;rules=Dict(:read=>Deny,:persistence=>Allow)))
        @test_throws ShenScopeError compiler_archive_list(store,readonly)
        budget=BudgetLedger(BudgetLimits(;max_seconds=0.01));budget.started_ns-=UInt64(1_000_000_000)
        expired=compiler_archive_context(root;budget)
        @test_throws ShenScopeError compiler_archive_get(store,report["report_sha256"],expired)
        unknown=joinpath(store.directory,"unknown.data");write(unknown,"unknown")
        @test_throws ShenScopeError compiler_archive_list(store,fresh)
        rm(unknown)
        policy=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Ask))
        asking=RuntimeContext(root;session_id=fresh.session_id,state_dir=fresh.state_dir,permissions=policy,
            approve=request->(push!(approvals,request.category);:once))
        @test compiler_archive_label(store,report["report_sha256"],"One approval",asking;expected_revision=1)["changed"]
        @test approvals==[:persistence]
        asking.sink=event->event.kind==:permission_resolved && (asking.permissions.rules[:persistence]=Deny)
        @test_throws ShenScopeError compiler_archive_delete(store,report["report_sha256"],asking;expected_revision=2)
        @test compiler_archive_list(store,fresh)["revision"]==2
    end
end
