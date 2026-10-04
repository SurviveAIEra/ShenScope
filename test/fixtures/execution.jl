function execution_fixture(;sandbox=ShenScope.HostSandbox(),rules=nothing,approve=request->:deny)
    root=mktempdir(;prefix="shenscope-execution-test-")
    state=joinpath(root,"state");mkpath(state)
    policy=rules===nothing ? Dict(:read=>Allow,:edit=>Allow,:process=>Allow,:network=>Deny,:persistence=>Deny) : rules
    ctx=RuntimeContext(root;state_dir=state,sandbox,permissions=PermissionPolicy(;rules=policy),approve)
    root,ctx
end

function execution_await_job(server,id)
    manager=ShenScope.server_security_tool(server).manager
    @test timedwait(()->manager.operations.jobs[id].status!=:running,30;pollint=0.01)==:ok
    manager.operations.jobs[id]
end

function execution_approve(server,owner;decision="once")
    @test timedwait(()->!isempty(server.approvals),30;pollint=0.01)==:ok
    id=first(keys(server.approvals))
    dispatch_rpc(server,"permissions/respond",Dict("session_id"=>owner,"request_id"=>id,"decision"=>decision))
    id
end
