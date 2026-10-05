function await_owned_operation(manager,id;timeout=10.0)
    timedwait(()->manager.jobs[id].status != :running,timeout;pollint=0.005) == :ok || error("Owned operation fixture timed out")
    manager.jobs[id]
end

@testset "Owned result limits preserve deep structured data and fail closed without expanding other managers" begin
    mktempdir() do root
        owner=RuntimeContext(root;state_dir=joinpath(root,"state"))
        value=Dict{String,Any}("leaf"=>"preserved")
        for _ in 1:30;value=Dict{String,Any}("child"=>value);end
        standard=OperationManager();expanded=OperationManager(;max_result_depth=40,max_result_nodes=256)
        try
            rejected=start_operation!(_->value,standard,owner;kind="deep")
            @test await_owned_operation(standard,rejected["job_id"]).error_code==:capacity
            retained=start_operation!(_->value,expanded,owner;kind="deep")
            @test await_owned_operation(expanded,retained["job_id"]).status==:complete
            @test owned_operation(expanded,retained["job_id"],owner)["result"]==value
            exhausted=OperationManager(;max_result_nodes=5)
            job=start_operation!(_->Dict("rows"=>collect(1:20)),exhausted,owner;kind="nodes")
            @test await_owned_operation(exhausted,job["job_id"]).error_code==:capacity
            close_operations!(exhausted)
            @test_throws ArgumentError OperationManager(;max_result_depth=true)
            @test_throws ArgumentError OperationManager(;max_result_depth=65)
            @test_throws ArgumentError OperationManager(;max_result_nodes=1_000_001)
        finally
            close_operations!(standard);close_operations!(expanded)
        end
    end
end

@testset "Nested operation approval ownership survives cancellation and scoped callbacks" begin
    mktempdir() do root
        events = AgentEvent[];seen = Ref{Any}(nothing)
        owner = RuntimeContext(root;state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(:network=>Ask)),
            approve=request->begin
                context = current_context();seen[] = context
                while !iscancelled(context.cancellation);sleep(0.01);end
                :deny
            end,sink=event->push!(events,event))
        manager = OperationManager();nested = Ref{Any}(nothing)
        started = start_operation!(manager,owner;kind="nested") do context
            child = child_context(context);nested[] = child
            ShenScope.authorize!(child,:network,"fixture","127.0.0.1")
            Dict("unused"=>true)
        end
        @test timedwait(()->seen[] !== nothing,10;pollint=0.01) == :ok
        @test seen[] === nested[]
        cancel!(nested[].cancellation,"Nested refresh invalidated")
        job = await_owned_operation(manager,started["job_id"]);wait(job.task)
        @test job.status == :cancelled && !iscancelled(owner.cancellation)
        view = owned_operation(manager,job.id,owner)
        request = only(filter(event->event.kind == :permission_request,events))
        @test view["permission_ids"] == [request.payload["id"]]
        complete = only(filter(event->event.kind == :operation_job_failed,events))
        @test complete.payload["permission_ids"] == view["permission_ids"]
        close_operations!(manager)
    end
end

@testset "Owned operations isolate cancellation, scopes, retention and notification failures" begin
    mktempdir() do root
        owner = RuntimeContext(root;session_id="owner",state_dir=joinpath(root,"state"))
        foreign = RuntimeContext(root;session_id="foreign",state_dir=owner.state_dir)
        manager = OperationManager(;max_running=2,max_jobs=4,max_result_bytes=512,max_retained_bytes=1024)
        ready = Channel{Bool}(1)
        started = start_operation!(manager,owner;kind="wait") do context
            put!(ready,true)
            while true;check_cancelled(context.cancellation);sleep(0.01);end
        end
        take!(ready)
        @test_throws ShenScopeError start_operation!(_->Dict(),manager,owner;kind="busy")
        @test_throws ShenScopeError owned_operation(manager,started["job_id"],foreign)
        other_state = RuntimeContext(root;session_id=owner.session_id,state_dir=joinpath(root,"other-state"))
        @test_throws ShenScopeError owned_operation(manager,started["job_id"],other_state;cancel=true)
        sibling = start_operation!(_->Dict("value"=>7),manager,foreign;kind="sibling")
        @test await_owned_operation(manager,sibling["job_id"]).result["value"] == 7
        owned_operation(manager,started["job_id"],owner;cancel=true)
        @test await_owned_operation(manager,started["job_id"]).status == :cancelled
        @test !iscancelled(owner.cancellation) && !iscancelled(foreign.cancellation)
        ids = String[]
        for _ in 1:3
            job = start_operation!(_->Dict("text"=>repeat("a",430)),manager,owner;kind="retained")
            push!(ids,job["job_id"]);@test await_owned_operation(manager,job["job_id"]).status == :complete
        end
        @test !haskey(manager.jobs,first(ids))
        @test sum(job.result_bytes for job in values(manager.jobs)) <= manager.max_retained_bytes
        oversized = start_operation!(_->Dict("text"=>repeat("x",1024)),manager,owner;kind="oversized")
        @test await_owned_operation(manager,oversized["job_id"]).error_code == :capacity
        executions = Ref(0)
        broken_sink = RuntimeContext(root;session_id="broken-sink",state_dir=owner.state_dir,sink=event->error("Transport closed"))
        delivered = start_operation!(manager,broken_sink;kind="notification") do context
            executions[] += 1;Dict("value"=>11)
        end
        job = await_owned_operation(manager,delivered["job_id"])
        wait(job.task)
        @test job.status == :complete && job.notification_failed && executions[] == 1
        @test owned_operation(manager,delivered["job_id"],broken_sink)["result"]["value"] == 11
        ShenScope.release_operations!(manager,owner.session_id)
        @test all(job.context.session_id != owner.session_id for job in values(manager.jobs))
        @test haskey(manager.jobs,delivered["job_id"])
        close_operations!(manager)
        @test isempty(manager.jobs) && manager.closed
        @test_throws ShenScopeError start_operation!(_->Dict(),manager,owner;kind="closed")
    end
end
