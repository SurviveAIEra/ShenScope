@testset "Execution access grants remain independent and revocable" begin
    if Sys.islinux()
        root,ctx=execution_fixture(;rules=Dict(:read=>Allow,:edit=>Deny,:process=>Allow,:network=>Deny))
        try
            write_sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy(;filesystem=:workspace_write))
            @test_throws ShenScopeError ShenScope.execution_plan(write_sandbox,["true"],ctx)
            ctx.permissions.rules[:edit]=Allow
            plan=ShenScope.execution_plan(write_sandbox,["true"],ctx)
            @test count(mount->mount.writable,plan.mounts)==1
            @test !ShenScope.execution_permission_denied(plan,ctx)
            ctx.permissions.rules[:edit]=Deny
            @test ShenScope.execution_permission_denied(plan,ctx)
            @test_throws ShenScopeError ShenScope.execution_recheck_permissions(plan,ctx)
            open_sandbox=ShenScope.BubblewrapSandbox(ShenScope.ExecutionPolicy(;network=:open))
            @test_throws ShenScopeError ShenScope.execution_plan(open_sandbox,["true"],ctx)
            ctx.permissions.rules[:network]=Allow
            open_plan=ShenScope.execution_plan(open_sandbox,["true"],ctx)
            @test "--share-net" in open_plan.command
            ctx.permissions.rules[:read]=Deny
            @test ShenScope.execution_permission_denied(open_plan,ctx)
            @test_throws ShenScopeError ShenScope.execution_plan(open_sandbox,["true"],ctx)
            ctx.permissions.rules[:read]=Allow
            cancel!(ctx.cancellation)
            @test_throws ShenScopeError ShenScope.execution_ready!(open_plan,ctx)
        finally
            rm(root;recursive=true)
        end
    end
end

@testset "Execution diagnostics are scoped metadata and require explicit probes" begin
    root,ctx=execution_fixture();manager=ShenScope.ExecutionManager()
    try
        @test isempty(manager.probes)
        status=ShenScope.execution_status(manager,ctx)
        @test status["policy"]["backend"]=="host" && !status["policy"]["os_isolation"]
        @test status["bubblewrap_probe"]===nothing && isempty(manager.probes)
        @test !status["automatic_host_fallback"]
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError ShenScope.execution_status(manager,ctx)
        ctx.permissions.rules[:read]=Allow;ctx.permissions.rules[:process]=Deny
        @test_throws ShenScopeError ShenScope.execution_probe!(manager,ctx)
        @test isempty(manager.probes)
        ctx.permissions.rules[:process]=Allow
        result=ShenScope.execution_probe!(manager,ctx)
        @test result["state"] in ("available","blocked","unconfirmed","unsupported_platform")
        @test !result["os_isolation"] && length(manager.probes)==1
        foreign=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
        @test ShenScope.execution_status(manager,foreign)["bubblewrap_probe"]===nothing
        @test ShenScope.execution_status(manager,ctx)["bubblewrap_probe"]["state"]==result["state"]
        @test_throws ShenScopeError execute(ShenScope.SecurityTool(manager),Dict("action"=>"probe","unknown"=>true),ctx)
        ShenScope.cleanup_execution!(manager)
        @test manager.closed && manager.operations.closed && isempty(manager.probes)
        @test_throws ShenScopeError ShenScope.execution_status(manager,ctx)
        @test_throws ShenScopeError ShenScope.execution_probe!(manager,ctx)
    finally
        ShenScope.cleanup_execution!(manager);rm(root;recursive=true)
    end
end
