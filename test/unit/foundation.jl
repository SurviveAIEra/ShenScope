@testset "Cancellation tree and dynamic context" begin
    mktempdir() do root
        parent = RuntimeContext(root;state_dir=joinpath(root,"state"))
        child = child_context(parent)
        @test parent.budget === child.budget
        @test parent.permissions === child.permissions
        with_context(parent) do
            @test current_context() === parent
            task = @async current_context()
            @test fetch(task) === parent
        end
        @test_throws ShenScopeError current_context()
        cancel!(parent.cancellation)
        @test iscancelled(child.cancellation)
        @test_throws ShenScopeError check_cancelled(child.cancellation)
    end
end

@testset "Concurrent budget reservation and accounting" begin
    b = BudgetLedger(BudgetLimits(;max_tokens=100,max_steps=5,max_cost=1.0))
    lease = reserve!(b,80,0.8)
    @test_throws ShenScopeError reserve!(b,21,0.1)
    @test_throws ShenScopeError reserve!(b,1,0.3)
    @test_throws ArgumentError reserve!(b,-1)
    settle!(b,lease,Usage(;input_tokens=40,output_tokens=10,cost=0.5))
    @test budget_status(b)["tokens"]==50
    @test budget_status(b)["reserved_tokens"]==0
    @test_throws ShenScopeError settle!(b,lease,Usage())
    second = reserve!(b,50,0.5)
    release!(b,second)
    @test budget_status(b)["reserved_cost"]==0
    @test budget_status(b)["reported_cost"]==0.5
    small = BudgetLedger(BudgetLimits(;max_tokens=10))
    outcomes = fetch.([Threads.@spawn(try reserve!(small,6) catch e; e end) for _ in 1:8])
    @test count(x->x isa String,outcomes)==1
end

@testset "Permission decisions and path containment" begin
    mktempdir() do root
        state = joinpath(root,"state")
        events = AgentEvent[]
        ctx = RuntimeContext(root;state_dir=state,approve=r->:session,sink=e->push!(events,e))
        authorize!(ctx,:edit,"edit","file")
        authorize!(ctx,:edit,"edit","file")
        @test count(e->e.kind==:permission_request,events)==1
        ctx.permissions.rules[:edit]=Deny
        @test_throws ShenScopeError authorize!(ctx,:edit,"edit","file")
        @test workspace_path(root,"new/file.txt")==joinpath(root,"new/file.txt")
        @test_throws ShenScopeError workspace_path(root,"../outside")
        @test_throws ShenScopeError workspace_path(root,".git/config")
        @test_throws ShenScopeError workspace_path(root,".env.test")
        symlink(dirname(root),joinpath(root,"escape"))
        @test_throws ShenScopeError workspace_path(root,"escape/new")
    end
end

@testset "Durable journal, torn tails and revision conflicts" begin
    mktempdir() do root
        j = Journal(joinpath(root,"j.jsonl"))
        @test append_record!(j,Dict("a"=>"中文");expected_revision=0)==1
        open(j.path,"a") do io;write(io,"{\"partial\":");end
        @test length(journal_records(j))==1
        @test append_record!(j,Dict("b"=>2);expected_revision=1)==2
        @test length(journal_records(j))==2
        @test_throws ShenScopeError append_record!(j,Dict("c"=>3);expected_revision=1)
        text=read(j.path,String)
        write(j.path,replace(text,"中文"=>"篡改"))
        @test_throws ShenScopeError journal_records(j)
    end
end

@testset "Session reconstruction and unknown side effects" begin
    mktempdir() do root
        state = joinpath(root,"state")
        ctx = RuntimeContext(root;state_dir=state)
        session = new_session(ctx;title="Repair 中文")
        call = ToolCall("edit",Dict("path"=>"file"))
        add_message!(session,Message(:user,"repair"))
        add_message!(session,Message(:assistant,"";calls=[call]))
        set_status!(session,:running)
        record_usage!(session,Usage(;input_tokens=10,output_tokens=2,cost=0.01))
        loaded=load_session(state,session.id)
        @test loaded.status==:interrupted
        @test length(loaded.messages)==2
        @test loaded.usage[1].input_tokens==10
        recover_tool_pairs!(loaded)
        @test loaded.messages[end].call_id==call.id
        @test occursin("effects unknown",loaded.messages[end].text)
        @test length(list_sessions(state;search="中文"))==1
        old=load_session(state,session.id)
        rename_session!(loaded,"New title")
        @test_throws ShenScopeError rename_session!(old,"Stale")
        childctx=RuntimeContext(root;state_dir=state)
        branch=branch_session(loaded,childctx;through=2)
        @test length(branch.messages)==3
        @test branch.metadata["parent"]==loaded.id
        @test isempty(branch.usage)
        @test_throws ShenScopeError load_session(state,"../escape")
    end
end
