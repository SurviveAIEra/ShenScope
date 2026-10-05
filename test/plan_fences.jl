using ShenScope,Test
isdefined(Main,:agent_plan_fixture) || include("fixtures/agent_plans.jl")
@testset "Actual cross-process run ownership and crash-released fences" begin
    mktempdir() do root
        ctx,session=agent_plan_fixture(root)
        command=`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__,"fixtures","plan_fence_worker.jl")) $root $(session.id)`
        ShenScope.with_session_run_fence(session,ctx) do
            @test read(`$command try`,String)=="REFUSED:session_busy\n"
            @test_throws ShenScopeError set_agent_mode!(session,ctx,"plan";expected_revision=0)
        end
        @test agent_mode_view(session)["revision"]==0
        output=Pipe();input=Pipe()
        worker=run(pipeline(`$command hold`;stdin=input,stdout=output);wait=false)
        close(output.in);close(input.out)
        try
            ready=@async readline(output)
            readiness=timedwait(()->istaskdone(ready),60;pollint=0.01)
            @test readiness==:ok
            readiness==:ok || error("Fence worker did not become ready")
            @test fetch(ready)=="FENCE_HELD"
            @test_throws ShenScopeError set_agent_mode!(session,ctx,"plan";expected_revision=0)
            kill(worker,Base.SIGKILL);wait(worker)
            @test !success(worker)
        finally
            !process_exited(worker) && (kill(worker,Base.SIGKILL);wait(worker))
            close(input.in);close(output)
        end
        @test set_agent_mode!(session,ctx,"plan";expected_revision=0)["committed"]
        @test agent_mode_view(load_session(ctx.state_dir,session.id))["mode"]=="plan"
        stale=load_session(ctx.state_dir,session.id)
        set_agent_mode!(session,ctx,"act";expected_revision=1)
        @test_throws ShenScopeError set_agent_mode!(stale,ctx,"plan";expected_revision=1)
        @test agent_mode_view(load_session(ctx.state_dir,session.id))["mode"]=="act"
    end
end
