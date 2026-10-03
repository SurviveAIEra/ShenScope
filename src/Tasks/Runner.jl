function run_leased_work!(executor::WorkExecutor, workflow::Workflow, record::WorkRecord,
        ctx::RuntimeContext; lease_seconds = 30.0)
    lease = record.lease
    lease === nothing && throw(ShenScopeError(:tasks, "Worker received an unleased task"))
    workerctx = child_context(ctx)
    started = false
    result = nothing
    failure = nothing
    fence_lost = false
    execution = nothing
    try
        start_work!(workflow, ctx, record.spec.id; worker = lease.worker, token = lease.token)
        started = true
        emit!(ctx, :work_started, Dict("workflow_id" => workflow.id, "task_id" => record.spec.id,
            "execution_id" => current_work_receipt(record).execution_id, "kind" => String(record.spec.kind)))
        outcome = Channel{Tuple{Bool,Any}}(1)
        execution = @async begin
            try
                value = with_context(() -> execute_work(executor, workflow, record, workerctx), workerctx)
                put!(outcome, (true, value))
            catch error
                put!(outcome, (false, error))
            end
        end
        deadline = time() + record.spec.timeout
        heartbeat_at = time() + lease_seconds / 3
        while !isready(outcome)
            if iscancelled(ctx.cancellation)
                cancel!(workerctx.cancellation, "Workflow worker cancelled")
            elseif time() >= deadline
                cancel!(workerctx.cancellation, "Task timeout")
                failure = WorkFailure(:timeout, "Task timeout elapsed", true, !record.spec.safe_retry)
            end
            if time() >= heartbeat_at && !fence_lost
                try
                    heartbeat = heartbeat_work!(workflow, ctx, record.spec.id;
                        worker = lease.worker, token = lease.token, lease_seconds)
                    heartbeat["cancel_requested"] && cancel!(workerctx.cancellation, "Task cancellation requested")
                    heartbeat_at = time() + lease_seconds / 3
                catch error
                    fence_lost = true
                    cancel!(workerctx.cancellation, "Unable to renew task lease")
                    failure = worker_failure(error, record.spec; interrupted = true)
                end
            end
            sleep(0.025)
        end
        succeeded, value = take!(outcome)
        if succeeded && failure === nothing && !iscancelled(workerctx.cancellation)
            result = value
        elseif failure === nothing
            failure = worker_failure(succeeded ? ShenScopeError(:cancelled, "Task cancelled during execution") : value, record.spec)
        end
    catch error
        failure = worker_failure(error, record.spec; interrupted = started)
        error isa ShenScopeError && error.code == :lease_lost && (fence_lost = true)
    finally
        cancel!(workerctx.cancellation, "Worker complete")
        execution !== nothing && !istaskdone(execution) && wait(execution)
    end
    # Cancellation of the runner must still leave a durable receipt. This context
    # retains the same scope, policy and budget but can perform the final write.
    receiptctx = RuntimeContext(ctx.root; session_id = ctx.session_id, state_dir = ctx.state_dir,
        budget = ctx.budget, permissions = ctx.permissions, sandbox = ctx.sandbox,
        approve = ctx.approve, sink = ctx.sink)
    if started && !fence_lost
        try
            view = finish_work!(workflow, receiptctx, record.spec.id; worker = lease.worker,
                token = lease.token, result, failure)
            emit!(ctx, :work_completed, Dict("workflow_id" => workflow.id, "task_id" => record.spec.id,
                "status" => view["status"], "attempt" => record.attempts))
            return view
        catch error
            emit!(ctx, :work_receipt_failed, Dict("workflow_id" => workflow.id, "task_id" => record.spec.id,
                "code" => error isa ShenScopeError ? String(error.code) : "internal"))
            rethrow()
        end
    end
    fence_lost && emit!(ctx, :work_lease_lost, Dict("workflow_id" => workflow.id, "task_id" => record.spec.id))
    nothing
end

function run_workflow!(executor::WorkExecutor, workflow::Workflow, ctx::RuntimeContext;
        concurrency = 4, kinds = collect(WORK_KINDS), lease_seconds = 30.0,
        wait_for_retries = true, max_seconds = 3600.0)
    concurrency isa Integer && !(concurrency isa Bool) && 1 <= concurrency <= 16 ||
        throw(ShenScopeError(:tasks, "Worker concurrency must be between one and sixteen"))
    max_seconds isa Real && !(max_seconds isa Bool) && isfinite(max_seconds) && 0.1 <= max_seconds <= 86400 ||
        throw(ShenScopeError(:tasks, "Invalid workflow execution deadline"))
    check_workflow_scope(workflow, ctx)
    token = CancellationToken(ctx.cancellation)
    runctx = child_context(ctx)
    runctx.cancellation = token
    hooks_barrier = worker_hooks_barrier(executor,runctx)
    deadline = time() + max_seconds
    workers = Task[]
    errors = Any[]
    guard = ReentrantLock()
    emit!(ctx, :workflow_started, Dict("workflow_id" => workflow.id, "concurrency" => concurrency))
    try
        for index in 1:concurrency
            worker = "worker-" * string(uuid4())
            push!(workers, @async begin
                try
                    while !iscancelled(token)
                        if time() >= deadline
                            cancel!(token, "Workflow deadline elapsed")
                            break
                        end
                        lock(runctx.budget.mutex) do; check_budget(runctx.budget); end
                        record = claim_work!(workflow, runctx; worker, kinds, lease_seconds, max_running = concurrency, hooks_barrier)
                        if record !== nothing
                            run_leased_work!(executor, workflow, record, runctx; lease_seconds)
                            continue
                        end
                        status = workflow_status(workflow, runctx)
                        counts = status["counts"]
                        counts["running"] > 0 || wait_for_retries && counts["retry_waiting"] > 0 || break
                        sleep(0.025)
                    end
                catch error
                    lock(guard) do; push!(errors, error); end
                    cancel!(token, "Workflow worker failed")
                end
            end)
        end
        foreach(wait, workers)
        isempty(errors) || throw(first(errors))
    finally
        cancel!(token, "Workflow run complete")
        foreach(task -> istaskdone(task) || wait(task), workers)
        cleanup_executor!(executor, ctx.session_id)
    end
    queryctx = RuntimeContext(ctx.root; session_id = ctx.session_id, state_dir = ctx.state_dir,
        budget = ctx.budget, permissions = ctx.permissions, approve = ctx.approve, sink = ctx.sink)
    status = workflow_status(workflow, queryctx)
    emit!(ctx, :workflow_completed, Dict("workflow_id" => workflow.id, "status" => status["status"]))
    status
end
