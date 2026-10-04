execution_prepare(::HostSandbox,argv,ctx;kwargs...)=nothing
execution_prepare(sandbox::BubblewrapSandbox,argv,ctx;kwargs...)=execution_plan(sandbox,argv,ctx;kwargs...)
execution_prepare(::AbstractSandbox,argv,ctx;kwargs...)=throw(ShenScopeError(:sandbox,"Execution sandbox has no launch implementation"))

function execution_permission_denied(plan::ExecutionPlan,ctx::RuntimeContext)
    requests=Tuple{Symbol,String,String}[(:read,"process.filesystem",plan.workspace)]
    plan.policy.filesystem==:workspace_write && push!(requests,(:edit,"process.filesystem",plan.workspace))
    plan.policy.network==:open && push!(requests,(:network,"process.network","*"))
    any(requests) do (category,tool,target)
        permission_decision(ctx.permissions,PermissionRequest("execution-active",category,tool,target,"Current execution permission"))==Deny
    end
end

function execution_ready!(plan::ExecutionPlan,ctx::RuntimeContext)
    execution_recheck_permissions(plan,ctx)
    probe=execution_probe_backend(ctx;authorized=true)
    probe.state==:available || throw(ShenScopeError(:sandbox,"Restricted command refused: "*probe.reason))
    execution_recheck_permissions(plan,ctx)
    nothing
end
