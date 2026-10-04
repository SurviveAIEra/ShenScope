@testset "Watcher options bound work and preserve ordinary runtime scopes" begin
    @test ProjectWatchOptions().automatic==false
    @test ProjectWatchOptions(poll_seconds=0.05,quiet_seconds=0.01).maximum_files==10000
    for bad in (0,-1,Inf,NaN,true,"1")
        @test_throws ShenScopeError ProjectWatchOptions(poll_seconds=bad)
    end
    for bad in (0,-1,Inf,NaN,true,"1")
        @test_throws ShenScopeError ProjectWatchOptions(quiet_seconds=bad)
    end
    @test_throws ShenScopeError ProjectWatchOptions(automatic=1)
    @test_throws ShenScopeError ProjectWatchOptions(native_hints=1)
    @test_throws ShenScopeError ProjectWatchOptions(maximum_files=10001)
    @test_throws ShenScopeError ProjectWatchOptions(maximum_files=true)
    @test_throws ShenScopeError ProjectWatchOptions(maximum_bytes=0)
    mktempdir() do root
        write(joinpath(root,"sample.jl"),"alpha")
        backend=WatchFixtureBackend();context=RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy())
        context.permissions.rules[:persistence]=Allow
        state=build!(backend,context);watch=ProjectWatch(backend,state,context)
        @test watch.context.cancellation.parent===context.cancellation
        @test watch.context.budget===context.budget && watch.context.permissions===context.permissions
        stop_project_watch!(watch)
        @test !iscancelled(context.cancellation)
        @test_throws ShenScopeError ProjectWatch(GoASTBackend(),state,context)
    end
end

@testset "Settling timer applies a stable hinted batch independently of a long poll interval" begin
    mktempdir() do root
        path=joinpath(root,"sample.jl");write(path,"alpha")
        backend=WatchFixtureBackend();ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        ctx.permissions.rules[:persistence]=Allow
        state=build!(backend,ctx)
        watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,native_hints=false,poll_seconds=10.0,quiet_seconds=0.1))
        try
            @test timedwait(()->watch.scans>0,5)==:ok
            write(path,"first change");ShenScope.wake_project_watch!(watch)
            @test timedwait(()->watch.phase==:pending,1;pollint=0.01)==:ok
            write(path,"final change");ShenScope.wake_project_watch!(watch)
            @test timedwait(()->watch.updates==1,2;pollint=0.01)==:ok
            @test state.revision==2 && state.files["sample.jl"].sha256==ShenScope.digest("final change")
            @test watch.native_events==0 && isempty(watch.dirty)
            stop_project_watch!(watch)
            @test !isopen(watch.timer) && (watch.settle_timer===nothing || !isopen(watch.settle_timer))
        finally;stop_project_watch!(watch);end
    end
end

@testset "Recursive watch snapshots share indexing scope and use actual content" begin
    mktempdir() do root
        mkpath(joinpath(root,"nested"));write(joinpath(root,"nested","source.jl"),"alpha")
        for ignored in (".git",".aws",".ssh","node_modules",".shenscope-staging","dist")
            mkpath(joinpath(root,ignored));write(joinpath(root,ignored,"hidden.jl"),"secret")
        end
        write(joinpath(root,"notes.txt"),"ignored")
        backend=WatchFixtureBackend();ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        ctx.permissions.rules[:persistence]=Allow
        state=build!(backend,ctx);watch=ProjectWatch(backend,state,ctx)
        first=ShenScope.scan_project_watch(watch)
        @test Set(keys(first.files))==Set(["nested/source.jl"])
        @test isempty(ShenScope.watch_snapshot_changes(watch.applied,first))
        file=joinpath(root,"nested","source.jl");before=stat(file)
        write(file,"bravo")
        if Sys.isunix()
            # Preserve mtime using Python only to exercise content freshness.
            run(`python3 -c $("import os; os.utime("*repr(file)*", ("*string(before.mtime)*", "*string(before.mtime)*"))")`)
        end
        second=ShenScope.scan_project_watch(watch)
        changes=ShenScope.watch_snapshot_changes(first,second)
        @test changes.modified==["nested/source.jl"]
        @test second.sha256!=first.sha256 && second.bytes==first.bytes
        rm(file);write(joinpath(root,"new.jl"),"created")
        third=ShenScope.scan_project_watch(watch);changes=ShenScope.watch_snapshot_changes(second,third)
        @test changes.created==["new.jl"] && changes.deleted==["nested/source.jl"]
        @test_throws ShenScopeError ShenScope.watch_changes_view(changes;offset=-1)
        @test ShenScope.watch_changes_view(changes;offset=99)["entries"]==[]
        if Sys.isunix()
            symlink(joinpath(root,"new.jl"),joinpath(root,"link.jl"))
            @test !haskey(ShenScope.scan_project_watch(watch).files,"link.jl")
        end
        limited=ProjectWatch(backend,state,ctx;options=ProjectWatchOptions(maximum_bytes=2))
        @test_throws ShenScopeError ShenScope.scan_project_watch(limited)
        ctx.permissions.rules[:read]=Deny
        @test_throws ShenScopeError ShenScope.scan_project_watch(watch)
    end
end

@testset "Quiet-window batches retain committed baseline across failure and require new content or explicit retry" begin
    mktempdir() do root
        path=joinpath(root,"sample.jl");write(path,"alpha")
        backend=WatchFixtureBackend();events=AgentEvent[]
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),sink=e->push!(events,e))
        ctx.permissions.rules[:persistence]=Allow
        state=build!(backend,ctx)
        watch=ProjectWatch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,quiet_seconds=0.1))
        write(path,"bravo");a=ShenScope.scan_project_watch(watch)
        @test ShenScope.observe_project_watch!(watch,a;now=1.0)==:pending
        write(path,"charlie");b=ShenScope.scan_project_watch(watch)
        @test ShenScope.observe_project_watch!(watch,b;now=1.05)==:pending
        @test ShenScope.observe_project_watch!(watch,b;now=1.16)==:stable
        @test state.revision==1
        @test ShenScope.apply_project_watch_batch!(watch)
        @test state.revision==2 && watch.updates==1 && state.files["sample.jl"].sha256==ShenScope.digest("charlie")
        committed=graph_snapshot(state);journal=read(state.journal.path);baseline=watch.applied.sha256
        write(path,"reject this explicit fixture")
        failed=ShenScope.scan_project_watch(watch)
        ShenScope.observe_project_watch!(watch,failed;now=2.0);ShenScope.observe_project_watch!(watch,failed;now=2.2)
        @test !ShenScope.apply_project_watch_batch!(watch)
        @test graph_snapshot(state)==committed && read(state.journal.path)==journal && state.revision==2
        @test watch.applied.sha256==baseline && watch.failed_updates==1 && !isempty(watch.dirty)
        attempts=backend.attempts
        @test !ShenScope.apply_project_watch_batch!(watch) && backend.attempts==attempts
        refresh_project_watch!(watch)
        @test !ShenScope.apply_project_watch_batch!(watch) && backend.attempts==attempts+1
        write(path,"repaired");fixed=ShenScope.scan_project_watch(watch)
        ShenScope.observe_project_watch!(watch,fixed;now=3.0);ShenScope.observe_project_watch!(watch,fixed;now=3.2)
        @test ShenScope.apply_project_watch_batch!(watch)
        @test state.revision==3 && watch.applied.sha256==fixed.sha256 && watch.last_error===nothing
        @test !any(event->event.kind==:model_request,events)
    end
end

@testset "Observe-only monitor owns native hints, timers, cancellation and persistence decisions" begin
    mktempdir() do root
        write(joinpath(root,"sample.jl"),"alpha")
        backend=WatchFixtureBackend();ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        ctx.permissions.rules[:persistence]=Allow
        state=build!(backend,ctx)
        watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(poll_seconds=0.05,quiet_seconds=0.02))
        try
            @test timedwait(()->project_watch_status(watch)["scans"]>=1,10)==:ok
            mkpath(joinpath(root,"nested"));write(joinpath(root,"nested","added.jl"),"new source")
            @test timedwait(()->project_watch_status(watch)["phase"]=="dirty",10)==:ok
            @test state.revision==1 && !haskey(state.files,"nested/added.jl")
            @test project_watch_status(watch)["changes"]["created"]==1
            refresh_project_watch!(watch)
            @test timedwait(()->project_watch_status(watch)["updates"]==1,10)==:ok
            @test state.revision==2 && haskey(state.files,"nested/added.jl")
            if Sys.isunix()
                @test timedwait(()->project_watch_status(watch)["native_events"]>0,5)==:ok
            end
            stop_project_watch!(watch)
            @test istaskdone(watch.task) && istaskdone(watch.monitor_task) && !isopen(watch.timer) && !isopen(watch.monitor)
            @test project_watch_status(watch)["phase"]=="stopped" && !iscancelled(ctx.cancellation)
            @test_throws ShenScopeError refresh_project_watch!(watch)
        finally
            stop_project_watch!(watch)
        end
        watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(native_hints=false,poll_seconds=0.05))
        @test timedwait(()->project_watch_status(watch)["scans"]>0,5)==:ok
        ctx.permissions.rules[:read]=Deny
        @test timedwait(()->istaskdone(watch.task),5)==:ok
        @test project_watch_status(watch)["phase"]=="failed" && project_watch_status(watch)["error"]["code"]=="permission"
        @test !iscancelled(ctx.cancellation)
    end
end

@testset "Nested periodic-only changes, rename, exhausted budgets and denied writes converge or stop without losing facts" begin
    mktempdir() do root
        mkpath(joinpath(root,"nested"));path=joinpath(root,"nested","sample.jl");write(path,"alpha")
        backend=WatchFixtureBackend();ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        ctx.permissions.rules[:persistence]=Allow
        state=build!(backend,ctx)
        watch=start_project_watch(backend,state,ctx;options=ProjectWatchOptions(automatic=true,native_hints=false,poll_seconds=0.05,quiet_seconds=0.02))
        try
            @test timedwait(()->watch.scans>0,5)==:ok
            write(path,"second")
            @test timedwait(()->watch.updates==1,5)==:ok
            @test state.files["nested/sample.jl"].sha256==ShenScope.digest("second") && watch.native_events==0
            mv(path,joinpath(root,"nested","renamed.jl"))
            @test timedwait(()->watch.updates==2,5)==:ok
            @test !haskey(state.files,"nested/sample.jl") && haskey(state.files,"nested/renamed.jl")
            before=graph_snapshot(state);journal=read(state.journal.path);revision=state.revision
            ctx.permissions.rules[:persistence]=Deny
            write(joinpath(root,"nested","renamed.jl"),"third")
            @test timedwait(()->istaskdone(watch.task),5)==:ok
            @test watch.phase==:failed && watch.last_error["code"]=="permission"
            @test state.revision==revision && graph_snapshot(state)==before && read(state.journal.path)==journal
            @test !iscancelled(ctx.cancellation)
        finally;stop_project_watch!(watch);end
        expired=BudgetLedger(BudgetLimits(max_seconds=0.01));expired.started_ns-=UInt64(1_000_000_000)
        short=RuntimeContext(root;state_dir=ctx.state_dir,permissions=ctx.permissions,budget=expired)
        watch=start_project_watch(backend,state,short;options=ProjectWatchOptions(native_hints=false))
        @test timedwait(()->istaskdone(watch.task),5)==:ok
        @test watch.phase==:failed && watch.last_error["code"]=="budget" && !iscancelled(short.cancellation)
        disconnected=RuntimeContext(root;state_dir=ctx.state_dir,permissions=ctx.permissions,sink=e->error("fixture sink closed"))
        watch=start_project_watch(backend,state,disconnected)
        @test timedwait(()->istaskdone(watch.task),5)==:ok
        @test watch.phase==:failed && watch.last_error["code"]=="watch_delivery"
        @test !isopen(watch.timer) && !isopen(watch.monitor) && istaskdone(watch.monitor_task)
    end
end
