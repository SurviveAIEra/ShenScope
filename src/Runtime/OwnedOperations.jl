mutable struct OwnedOperation
    id::String
    kind::String
    context::RuntimeContext
    metadata::Dict{String,Any}
    status::Symbol
    result::Union{Nothing,Dict{String,Any}}
    error::Union{Nothing,String}
    error_code::Union{Nothing,Symbol}
    task::Union{Nothing,Task}
    started_at::Float64
    finished_at::Union{Nothing,Float64}
    result_bytes::Int
    notification_failed::Bool
    pending_permissions::Set{String}
end

mutable struct OperationManager
    jobs::Dict{String,OwnedOperation}
    mutex::ReentrantLock
    event_prefix::String
    max_running::Int
    max_per_session::Int
    max_jobs::Int
    max_result_bytes::Int
    max_retained_bytes::Int
    closed::Bool
end

function OperationManager(;event_prefix="operation",max_running=4,max_per_session=1,
        max_jobs=64,max_result_bytes=4*1024^2,max_retained_bytes=16*1024^2)
    occursin(r"^[a-z][a-z0-9_]{0,31}$",event_prefix) || throw(ArgumentError("Invalid operation event prefix"))
    values = (max_running,max_per_session,max_jobs,max_result_bytes,max_retained_bytes)
    all(value -> value isa Integer && !(value isa Bool),values) &&
        1 <= max_per_session <= max_running <= 64 && max_running <= max_jobs <= 1024 &&
        128 <= max_result_bytes <= max_retained_bytes <= 64*1024^2 ||
        throw(ArgumentError("Invalid owned operation capacities"))
    OperationManager(Dict(),ReentrantLock(),String(event_prefix),values...,false)
end

operation_scope(ctx::RuntimeContext) = (ctx.root,ctx.state_dir,ctx.session_id)

function operation_view(job::OwnedOperation)
    Dict("job_id"=>job.id,"action"=>job.kind,"session_id"=>job.context.session_id,
        "metadata"=>deepcopy(job.metadata),"status"=>String(job.status),"result"=>deepcopy(job.result),
        "error"=>job.error,"error_code"=>job.error_code === nothing ? nothing : String(job.error_code),
        "started_at"=>job.started_at,"finished_at"=>job.finished_at,"result_bytes"=>job.result_bytes,
        "notification_failed"=>job.notification_failed,"permission_ids"=>sort!(collect(job.pending_permissions)))
end

function operations_running(manager::OperationManager;session_id=nothing)
    lock(manager.mutex) do
        any(job -> job.status == :running && (session_id === nothing || job.context.session_id == session_id),values(manager.jobs))
    end
end

function retain_operation!(manager::OperationManager,job::OwnedOperation,result::AbstractDict)
    bytes = ncodeunits(bounded_canonical_json(result;maximum=manager.max_result_bytes))
    bytes <= manager.max_result_bytes || throw(ShenScopeError(:capacity,"Operation result exceeds its transport capacity"))
    lock(manager.mutex) do
        completed = sort!([prior for prior in values(manager.jobs) if prior.status != :running];by=prior -> prior.finished_at)
        retained = sum(prior.result_bytes for prior in completed;init=0)
        for prior in completed
            retained + bytes <= manager.max_retained_bytes && break
            delete!(manager.jobs,prior.id);retained -= prior.result_bytes
        end
        check_cancelled(job.context.cancellation)
        job.result = deepcopy(Dict{String,Any}(result));job.result_bytes = bytes
        job.status = :complete;job.finished_at = time()
    end
    nothing
end

function start_operation!(work::Function,manager::OperationManager,owner::RuntimeContext;
        kind::String,metadata=Dict{String,Any}())
    occursin(r"^[a-z][a-z0-9._-]{0,63}$",kind) || throw(ShenScopeError(:arguments,"Invalid operation kind"))
    bounded_canonical_json(metadata;maximum=4096)
    check_cancelled(owner.cancellation)
    context = child_context(owner)
    job = OwnedOperation(string(uuid4()),kind,context,deepcopy(Dict{String,Any}(metadata)),:running,
        nothing,nothing,nothing,nothing,time(),nothing,0,false,Set{String}())
    context.sink = event -> begin
        if event.kind in (:permission_request,:permission_resolved)
            id = event.payload["id"]
            lock(manager.mutex) do
                if event.kind == :permission_request
                    length(job.pending_permissions) < 64 || throw(ShenScopeError(:capacity,"Operation pending permission capacity reached"))
                    push!(job.pending_permissions,id)
                else
                    delete!(job.pending_permissions,id)
                end
            end
        end
        owner.sink(event)
    end
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Operation manager is closed"))
        count(prior -> prior.status == :running,values(manager.jobs)) < manager.max_running ||
            throw(ShenScopeError(:capacity,"Operation concurrency capacity reached"))
        count(prior -> prior.status == :running && operation_scope(prior.context) == operation_scope(owner),values(manager.jobs)) < manager.max_per_session ||
            throw(ShenScopeError(:runtime,"An operation is already running in this conversation"))
        if length(manager.jobs) >= manager.max_jobs
            completed = sort!([prior for prior in values(manager.jobs) if prior.status != :running];by=prior -> prior.finished_at)
            isempty(completed) && throw(ShenScopeError(:capacity,"Operation retention capacity reached"))
            delete!(manager.jobs,first(completed).id)
        end
        manager.jobs[job.id] = job
    end
    job.task = @async with_context(context) do
        try
            check_cancelled(context.cancellation)
            result = work(context)
            result isa AbstractDict || throw(ShenScopeError(:protocol,"Operation must return a JSON object"))
            lock(context.budget.mutex) do;check_budget(context.budget);end
            retain_operation!(manager,job,result)
        catch cause
            lock(manager.mutex) do
                job.status = iscancelled(context.cancellation) || cause isa ShenScopeError && cause.code == :cancelled ? :cancelled : :failed
                job.error = cause isa ShenScopeError ? cause.message : "Operation failed"
                job.error_code = cause isa ShenScopeError ? cause.code : :internal
                job.finished_at = time()
            end
        end
        # A disconnected notification sink cannot turn completed work into a
        # failed operation or prevent retirement of the owning task.
        try
            suffix = job.status == :complete ? "_job_completed" : "_job_failed"
            emit!(context,Symbol(manager.event_prefix*suffix),operation_view(job))
        catch
            lock(manager.mutex) do;job.notification_failed = true;end
        end
    end
    Dict("job_id"=>job.id,"started"=>true)
end

function owned_operation(manager::OperationManager,id::AbstractString,ctx::RuntimeContext;cancel=false)
    lock(manager.mutex) do
        job = get(manager.jobs,String(id),nothing)
        job !== nothing || throw(ShenScopeError(:runtime,"Operation does not exist or has been retired"))
        operation_scope(job.context) == operation_scope(ctx) || throw(ShenScopeError(:permission,"Operation belongs to another conversation or workspace"))
        cancel && job.status == :running && cancel!(job.context.cancellation,"Operation cancelled by its owning conversation")
        operation_view(job)
    end
end

function close_operations!(manager::OperationManager)
    jobs = lock(manager.mutex) do
        manager.closed = true
        owned = collect(values(manager.jobs))
        for job in owned;job.status == :running && cancel!(job.context.cancellation,"Operation manager closing");end
        owned
    end
    for job in jobs
        job.task === nothing || job.task === current_task() || wait(job.task)
    end
    lock(manager.mutex) do;empty!(manager.jobs);end
    nothing
end

function release_operations!(manager::OperationManager,session_id::String;root=nothing)
    jobs = lock(manager.mutex) do
        owned = [job for job in values(manager.jobs) if job.context.session_id == session_id &&
            (root === nothing || job.context.root == root)]
        for job in owned;job.status == :running && cancel!(job.context.cancellation,"Conversation operations retiring");end
        owned
    end
    for job in jobs;job.task === nothing || job.task === current_task() || wait(job.task);end
    lock(manager.mutex) do
        for job in jobs;get(manager.jobs,job.id,nothing) === job && delete!(manager.jobs,job.id);end
    end
    nothing
end
