function workspace_replacement(ctx,path,old,new)
    snapshot=read_workspace_snapshot(ctx,path)
    match=findfirst(old,snapshot.source.source)
    start=first(match);after=start+ncodeunits(old)
    line,column=ShenScope.source_position(snapshot.source,start)
    last_line,last_column=ShenScope.source_position(snapshot.source,after)
    location=SourceRange(snapshot.path,line,last_line;start_column=column,end_column=last_column)
    Dict("path"=>snapshot.path,"expected_sha256"=>snapshot.sha256,
        "edits"=>[Dict("location"=>ShenScope.range_dict(location),"new_text"=>new)])
end

function workspace_fixture(root)
    write(joinpath(root,"a.py"),"value = '中😀old'\n")
    write(joinpath(root,"b.js"),"const value = 'old';\n")
    ctx=model_context(root);manager=WorkspaceEditManager()
    ctx,manager,[workspace_replacement(ctx,"a.py","old","new"),workspace_replacement(ctx,"b.js","old","new")]
end

@testset "Workspace proposals preview Unicode edits and refuse stale, overlapping and foreign operations" begin
    mktempdir() do root
        ctx,manager,files=workspace_fixture(root)
        plan=prepare_workspace_edits!(manager,ctx,files)
        @test plan["status"]=="prepared" && plan["requires_explicit_apply"]
        @test !plan["multi_file_power_loss_atomic"] && !occursin("new",read(joinpath(root,"a.py"),String))
        preview=preview_workspace_edits(manager,plan["plan_id"],ctx;include_text=true)
        @test preview["source_current"] && occursin("中😀new",preview["files"][1]["after_text"])
        @test read_workspace_edit_source(manager,plan["plan_id"],"a.py",ctx)["content_is_current_disk_source"]==false
        duplicate=deepcopy(files);push!(duplicate,files[1])
        @test_throws ShenScopeError prepare_workspace_edits!(manager,ctx,duplicate)
        overlapping=deepcopy(files[1]);push!(overlapping["edits"],deepcopy(overlapping["edits"][1]))
        @test_throws ShenScopeError prepare_workspace_edits!(manager,ctx,[overlapping])
        foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
        @test_throws ShenScopeError read_workspace_edit_plan(manager,plan["plan_id"],foreign)
        @test_throws ShenScopeError apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=digest("other"))
        write(joinpath(root,"b.js"),"external modification\n")
        receipt=apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"])
        @test receipt["outcome"]=="not_applied" && occursin("old",read(joinpath(root,"a.py"),String))
        @test read(joinpath(root,"b.js"),String)=="external modification\n"
        @test_throws ShenScopeError apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"])
    end
end

@testset "Workspace application retains receipts and rolls back without overwriting external edits" begin
    for external in (false,true)
        mktempdir() do root
            ctx,manager,files=workspace_fixture(root)
            plan=prepare_workspace_edits!(manager,ctx,files)
            receipt=apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"],
                before_file=(index,file)->begin
                    if index==2
                        external && write(joinpath(root,"a.py"),"user edited while transaction ran\n")
                        throw(ShenScopeError(:fixture_io,"injected ordinary failure"))
                    end
                end)
            @test receipt["outcome"]==(external ? "partial" : "rolled_back")
            @test read(joinpath(root,"a.py"),String)==(external ? "user edited while transaction ran\n" : "value = '中😀old'\n")
            @test read(joinpath(root,"b.js"),String)=="const value = 'old';\n"
            @test receipt["rollback_conflicts"]==(external ? ["a.py"] : String[])
            @test read_workspace_edit_plan(manager,plan["plan_id"],ctx)["receipt"]["sha256"]==receipt["sha256"]
        end
    end
    mktempdir() do root
        ctx,manager,files=workspace_fixture(root)
        plan=prepare_workspace_edits!(manager,ctx,files)
        ctx.sink=event->throw(ShenScopeError(:fixture,"lost notification"))
        receipt=apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"])
        @test receipt["outcome"]=="applied" && occursin("new",read(joinpath(root,"b.js"),String))
        body=Dict(key=>value for (key,value) in receipt if key!="sha256")
        @test digest(canonical(body))==receipt["sha256"]
        @test read_workspace_edit_plan(manager,plan["plan_id"],ctx)["status"]=="applied"
        @test_throws ShenScopeError apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"])
    end
end

@testset "Workspace edit permissions, plan mode and bounded proposals remain independent" begin
    mktempdir() do root
        ctx,manager,files=workspace_fixture(root)
        plan=with_agent_execution_mode(AgentPlan) do
            prepare_workspace_edits!(manager,ctx,files)
        end
        blocked=with_agent_execution_mode(AgentPlan) do
            apply_workspace_edits!(manager,plan["plan_id"],ctx;expected_plan_sha256=plan["plan_sha256"])
        end
        @test blocked["outcome"]=="not_applied" && blocked["error_code"]=="agent_mode"
        @test occursin("old",read(joinpath(root,"a.py"),String))
        fresh=prepare_workspace_edits!(manager,ctx,files)
        ctx.permissions.rules[:edit]=Deny
        @test apply_workspace_edits!(manager,fresh["plan_id"],ctx;expected_plan_sha256=fresh["plan_sha256"])["outcome"]=="not_applied"
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError preview_workspace_edits(manager,fresh["plan_id"],ctx)
    end
end
