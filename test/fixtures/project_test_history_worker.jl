using ShenScope
root,session_id,run_id,label,gate=ARGS
ctx=RuntimeContext(root;session_id,state_dir=joinpath(root,"state"),permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow)))
store=project_test_history_store(ctx)
list_project_test_history(store,ctx)
write(joinpath(root,label*".ready"),"ready\n")
timedwait(()->isfile(gate),180;pollint=0.05)==:ok || error("History contention gate timed out")
try
    result=label_project_test_history!(store,run_id,label,ctx;expected_revision=1)
    println(result["changed"] ? "changed" : "unchanged")
catch cause
    cause isa ShenScopeError && cause.code==:conflict || rethrow()
    println("conflict")
end
