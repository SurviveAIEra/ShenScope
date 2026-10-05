using ShenScope
root,id,operation=ARGS
ctx=RuntimeContext(root;session_id=id,state_dir=joinpath(root,"state"))
session=load_session(ctx.state_dir,id)
if operation=="hold"
    ShenScope.with_session_run_fence(session,ctx) do
        println("FENCE_HELD");flush(stdout)
        read(stdin,UInt8)
    end
elseif operation=="try"
    try
        set_agent_mode!(session,ctx,"plan";expected_revision=agent_mode_view(session)["revision"])
        println("MODE_CHANGED")
    catch error
        error isa ShenScopeError || rethrow()
        println("REFUSED:"*String(error.code))
    end
else
    error("Unknown fence fixture operation")
end
