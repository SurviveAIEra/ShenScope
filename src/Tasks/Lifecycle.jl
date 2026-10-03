function valid_work_clock(now::Real)
    !(now isa Bool) && isfinite(now) && now >= 0 || throw(ShenScopeError(:tasks, "Invalid task clock"))
    Float64(now)
end

function current_work_receipt(record::WorkRecord)
    isempty(record.receipts) && throw(ShenScopeError(:tasks, "Task has no execution receipt"))
    last(record.receipts)
end

function replace_work_receipt(record::WorkRecord, phase::Symbol; now,
        result_sha256 = nothing, evidence = "")
    current = current_work_receipt(record)
    finished = phase in (:claimed, :started) ? nothing : max(Float64(now), current.started_at)
    receipt = WorkReceipt(current.execution_id, current.attempt, phase, current.started_at,
        finished, result_sha256, cliptext(evidence, 4096))
    vcat(record.receipts[1:end-1], [receipt])
end

function check_work_lease(record::WorkRecord, worker::String, token::String, now::Real)
    record.status == WorkRunning && record.lease !== nothing ||
        throw(ShenScopeError(:tasks, "Task has no active lease"))
    lease = record.lease
    lease.worker == worker && lease.token == token && lease.generation == record.attempts ||
        throw(ShenScopeError(:lease_lost, "Task lease belongs to another execution"))
    lease.expires_at > now || throw(ShenScopeError(:lease_lost, "Task lease expired"))
    lease
end

function recover_expired_work!(tasks::Dict{String,WorkRecord}, changed::Set{String}, now::Float64)
    for (id, record) in tasks
        if record.status == WorkRetryWaiting && record.not_before <= now
            tasks[id] = replace_work(record; status = WorkReady, not_before = 0.0)
            push!(changed, id)
            continue
        end
        record.status == WorkRunning || continue
        record.lease.expires_at <= now || continue
        receipt = current_work_receipt(record)
        effects_uncertain = receipt.phase == :started && !record.spec.safe_retry
        failure = WorkFailure(:lease_expired, "Execution lease expired before a durable completion", true, effects_uncertain)
        if effects_uncertain
            status = WorkUncertain
            not_before = 0.0
        elseif record.cancel_requested
            status = WorkCancelled
            not_before = 0.0
        elseif record.attempts < record.spec.retry.max_attempts
            status = WorkRetryWaiting
            not_before = now + work_retry_delay(record.spec, record.attempts)
        else
            status = WorkFailed
            not_before = 0.0
        end
        receipts = replace_work_receipt(record, :interrupted; now, evidence = failure.message)
        tasks[id] = replace_work(record; status, lease = nothing, failure, not_before, receipts)
        push!(changed, id)
    end
    changed
end

function recover_workflow!(workflow::Workflow, ctx::RuntimeContext; now = time())
    clock = valid_work_clock(now)
    mutate_workflow!(workflow, ctx; operation = "recover") do tasks, changed
        recover_expired_work!(tasks, changed, clock)
        sort!(collect(changed))
    end
end

function claim_work!(workflow::Workflow, ctx::RuntimeContext; worker::AbstractString,
        kinds = collect(WORK_KINDS), lease_seconds = 30.0, max_running = 8, now = time())
    owner = valid_id(worker)
    clock = valid_work_clock(now)
    isfinite(lease_seconds) && 1 <= lease_seconds <= 3600 || throw(ShenScopeError(:tasks, "Invalid lease duration"))
    max_running isa Integer && !(max_running isa Bool) && 1 <= max_running <= 64 || throw(ShenScopeError(:tasks, "Invalid workflow concurrency"))
    permitted = Set(Symbol.(kinds))
    issubset(permitted, WORK_KINDS) || throw(ShenScopeError(:tasks, "Unknown worker capability"))
    mutate_workflow!(workflow, ctx; operation = "claim") do tasks, changed
        recover_expired_work!(tasks, changed, clock)
        propagate_work_dependencies!(tasks, workflow.children, changed)
        count(record -> record.status == WorkRunning, values(tasks)) < max_running || return nothing
        candidates = [record for record in values(tasks) if record.status == WorkReady &&
            record.spec.kind in permitted && !record.cancel_requested]
        isempty(candidates) && return nothing
        sort!(candidates; by = record -> (-record.spec.priority, record.spec.id))
        active = [record for record in values(tasks) if record.status == WorkRunning]
        any(record -> !work_replay_safe(record.spec.kind, record.spec.operation, record.spec.arguments), active) && return nothing
        eligible = filter(record -> isempty(active) || work_replay_safe(record.spec.kind, record.spec.operation, record.spec.arguments), candidates)
        isempty(eligible) && return nothing
        record = first(eligible)
        record.attempts < record.spec.retry.max_attempts || throw(ShenScopeError(:tasks, "Ready task exhausted its attempts"))
        attempt = record.attempts + 1
        lease = WorkLease(owner, string(uuid4()), attempt, clock, clock + lease_seconds)
        receipt = WorkReceipt(string(uuid4()), attempt, :claimed, clock, nothing, nothing, "")
        next = replace_work(record; status = WorkRunning, attempts = attempt, lease,
            not_before = 0.0, failure = nothing, receipts = vcat(record.receipts, [receipt]))
        tasks[record.spec.id] = next
        push!(changed, record.spec.id)
        deepcopy(next)
    end
end

function start_work!(workflow::Workflow, ctx::RuntimeContext, id::AbstractString;
        worker::AbstractString, token::AbstractString, now = time())
    identifier = valid_id(id)
    owner = valid_id(worker)
    credential = valid_id(token)
    clock = valid_work_clock(now)
    mutate_workflow!(workflow, ctx; operation = "start") do tasks, changed
        record = get(tasks, identifier, nothing)
        record === nothing && throw(ShenScopeError(:tasks, "Task does not exist"))
        check_work_lease(record, owner, credential, clock)
        record.cancel_requested && throw(ShenScopeError(:cancelled, "Task cancellation was requested"))
        current_work_receipt(record).phase == :claimed || throw(ShenScopeError(:tasks, "Task execution already started"))
        receipts = replace_work_receipt(record, :started; now = clock)
        tasks[identifier] = replace_work(record; receipts)
        push!(changed, identifier)
        work_view(tasks[identifier])
    end
end

function heartbeat_work!(workflow::Workflow, ctx::RuntimeContext, id::AbstractString;
        worker::AbstractString, token::AbstractString, lease_seconds = 30.0, now = time())
    clock = valid_work_clock(now)
    isfinite(lease_seconds) && 1 <= lease_seconds <= 3600 || throw(ShenScopeError(:tasks, "Invalid lease duration"))
    mutate_workflow!(workflow, ctx; operation = "heartbeat") do tasks, changed
        record = get(tasks, valid_id(id), nothing)
        record === nothing && throw(ShenScopeError(:tasks, "Task does not exist"))
        lease = check_work_lease(record, valid_id(worker), valid_id(token), clock)
        expiry = max(lease.expires_at, clock + lease_seconds)
        next_lease = WorkLease(lease.worker, lease.token, lease.generation, lease.issued_at, expiry)
        tasks[record.spec.id] = replace_work(record; lease = next_lease)
        push!(changed, record.spec.id)
        Dict("expires_at" => expiry, "cancel_requested" => record.cancel_requested)
    end
end

function finish_work!(workflow::Workflow, ctx::RuntimeContext, id::AbstractString;
        worker::AbstractString, token::AbstractString, result = nothing,
        failure::Union{Nothing,WorkFailure} = nothing, now = time())
    clock = valid_work_clock(now)
    serialized = serialize_work_result(result)
    mutate_workflow!(workflow, ctx; operation = "finish") do tasks, changed
        record = get(tasks, valid_id(id), nothing)
        record === nothing && throw(ShenScopeError(:tasks, "Task does not exist"))
        check_work_lease(record, valid_id(worker), valid_id(token), clock)
        current_work_receipt(record).phase == :started || throw(ShenScopeError(:tasks, "Task execution has not started"))
        stored_result = failure === nothing ? store_work_result_locked!(workflow, serialized) : nothing
        if failure === nothing
            status = WorkSucceeded
            not_before = 0.0
            receipt_phase = :succeeded
        elseif failure.effects_uncertain
            status = WorkUncertain
            not_before = 0.0
            receipt_phase = :interrupted
        elseif record.cancel_requested || failure.code == :cancelled
            status = WorkCancelled
            not_before = 0.0
            receipt_phase = :cancelled
        elseif failure.retryable && record.spec.safe_retry && record.attempts < record.spec.retry.max_attempts
            status = WorkRetryWaiting
            not_before = clock + work_retry_delay(record.spec, record.attempts)
            receipt_phase = :failed
        else
            status = WorkFailed
            not_before = 0.0
            receipt_phase = :failed
        end
        evidence = failure === nothing ? "Completion acknowledged by execution owner" : failure.message
        receipts = replace_work_receipt(record, receipt_phase; now = clock,
            result_sha256 = failure === nothing ? digest(serialized) : nothing, evidence)
        tasks[record.spec.id] = replace_work(record; status, lease = nothing, not_before,
            result = stored_result, failure, receipts)
        push!(changed, record.spec.id)
        work_view(tasks[record.spec.id])
    end
end

function cancel_work!(workflow::Workflow, ctx::RuntimeContext, ids::AbstractVector;
        cascade = true, expected_revision = nothing)
    identifiers = valid_id.(ids)
    length(identifiers) <= MAX_WORKFLOW_TASKS || throw(ShenScopeError(:tasks, "Cancellation batch exceeds limit"))
    mutate_workflow!(workflow, ctx; expected_revision, operation = "cancel") do tasks, changed
        all(id -> haskey(tasks, id), identifiers) || throw(ShenScopeError(:tasks, "Cancellation task does not exist"))
        selected = cascade ? work_descendants(workflow.children, identifiers) : identifiers
        for id in selected
            record = tasks[id]
            record.status in WORK_TERMINAL_STATUSES && continue
            record.status == WorkUncertain && continue
            status = record.status == WorkRunning ? WorkRunning : WorkCancelled
            tasks[id] = replace_work(record; status, cancel_requested = true,
                failure = record.status == WorkRunning ? record.failure : WorkFailure(:cancelled, "Task cancelled before execution", false, false))
            push!(changed, id)
        end
        sort!(collect(changed))
    end
end

function reconcile_work!(workflow::Workflow, ctx::RuntimeContext, id::AbstractString;
        disposition::Symbol, evidence::AbstractString, result = nothing, expected_version = nothing, now = time())
    disposition in (:succeeded, :failed, :retry) || throw(ShenScopeError(:tasks, "Unknown reconciliation disposition"))
    1 <= ncodeunits(evidence) <= 4096 || throw(ShenScopeError(:tasks, "Reconciliation evidence is required"))
    clock = valid_work_clock(now)
    serialized = serialize_work_result(result)
    mutate_workflow!(workflow, ctx; operation = "reconcile") do tasks, changed
        record = get(tasks, valid_id(id), nothing)
        record === nothing && throw(ShenScopeError(:tasks, "Task does not exist"))
        record.status == WorkUncertain || throw(ShenScopeError(:tasks, "Only uncertain executions require reconciliation"))
        expected_version === nothing || expected_version == record.version || throw(ShenScopeError(:conflict, "Task version changed"))
        disposition == :retry && record.attempts >= record.spec.retry.max_attempts &&
            throw(ShenScopeError(:tasks, "Task attempt limit reached"))
        stored_result = disposition == :succeeded ? store_work_result_locked!(workflow, serialized) : nothing
        status = disposition == :succeeded ? WorkSucceeded : disposition == :failed ? WorkFailed : WorkReady
        failure = disposition == :failed ? WorkFailure(:reconciled, String(evidence), false, false) : nothing
        receipts = replace_work_receipt(record, :reconciled; now = clock,
            result_sha256 = disposition == :succeeded ? digest(serialized) : nothing, evidence)
        tasks[record.spec.id] = replace_work(record; status, failure, receipts,
            result = stored_result,
            not_before = 0.0, cancel_requested = false)
        push!(changed, record.spec.id)
        work_view(tasks[record.spec.id])
    end
end
