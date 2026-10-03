struct HostSandbox <: AbstractSandbox end

mutable struct RuntimeContext
    session_id::String
    root::String
    state_dir::String
    trace_id::String
    cancellation::CancellationToken
    budget::BudgetLedger
    permissions::PermissionPolicy
    sandbox::AbstractSandbox
    approve::Function
    sink::Function
    sequence::Int
    mutex::ReentrantLock
end
function RuntimeContext(root::AbstractString; session_id=string(uuid4()),
        state_dir=get(ENV,"SHENSCOPE_STATE_DIR",joinpath(homedir(),".local/state/shenscope")),
        cancellation=CancellationToken(), budget=BudgetLedger(), permissions=PermissionPolicy(),
        sandbox=HostSandbox(), approve=r->:deny, sink=e->nothing)
    RuntimeContext(session_id,realpath(root),abspath(state_dir),string(uuid4()),cancellation,
        budget,permissions,sandbox,approve,sink,0,ReentrantLock())
end

const CURRENT_CONTEXT = ScopedValue{Union{Nothing,RuntimeContext}}(nothing)
function current_context()
    ctx = CURRENT_CONTEXT[]
    ctx === nothing && throw(ShenScopeError(:context,"No active runtime context"))
    return ctx
end
with_context(f::Function,ctx::RuntimeContext) = with(f,CURRENT_CONTEXT=>ctx)

function emit!(ctx::RuntimeContext, kind::Symbol, payload=nothing)
    lock(ctx.mutex) do
        ctx.sequence += 1
        event = AgentEvent(ctx.sequence,kind,ctx.session_id,ctx.trace_id,utcstamp(),payload)
        ctx.sink(event)
        return event
    end
end

function authorize!(ctx::RuntimeContext, category::Symbol, tool::AbstractString,
        target::AbstractString; reason="Tool execution")
    check_cancelled(ctx.cancellation)
    request = PermissionRequest(string(uuid4()),category,String(tool),String(target),reason)
    decision = permission_decision(ctx.permissions,request)
    decision == Deny && throw(ShenScopeError(:permission,"Operation denied by policy"))
    decision == Allow && return nothing
    emit!(ctx,:permission_request,Dict("id"=>request.id,"category"=>String(category),
        "tool"=>request.tool,"target"=>request.target,"reason"=>request.reason))
    answer = ctx.approve(request)
    check_cancelled(ctx.cancellation)
    answer in (:once,:session) || throw(ShenScopeError(:permission,"Operation not approved"))
    if answer == :session
        lock(ctx.permissions.mutex) do
            push!(ctx.permissions.grants,(category,String(target)))
        end
    end
    emit!(ctx,:permission_resolved,Dict("id"=>request.id,"decision"=>String(answer)))
    return nothing
end

function child_context(parent::RuntimeContext; session_id=parent.session_id, sink=parent.sink)
    RuntimeContext(parent.root;session_id,state_dir=parent.state_dir,
        cancellation=CancellationToken(parent.cancellation),budget=parent.budget,
        permissions=parent.permissions,sandbox=parent.sandbox,approve=parent.approve,sink)
end
