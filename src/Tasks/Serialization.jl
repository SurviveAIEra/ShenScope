function work_lease_dict(lease::WorkLease; include_token = true)
    value = Dict{String,Any}("worker" => lease.worker, "generation" => lease.generation,
        "issued_at" => lease.issued_at, "expires_at" => lease.expires_at)
    include_token && (value["token"] = lease.token)
    value
end

function work_lease_from(value::AbstractDict)
    worker = valid_id(value["worker"])
    token = valid_id(value["token"])
    generation = value["generation"]
    issued = value["issued_at"]
    expiry = value["expires_at"]
    generation isa Integer && !(generation isa Bool) && generation > 0 || throw(ShenScopeError(:storage, "Invalid lease generation"))
    issued isa Real && expiry isa Real && isfinite(issued) && isfinite(expiry) && issued < expiry ||
        throw(ShenScopeError(:storage, "Invalid lease timestamps"))
    WorkLease(worker, token, generation, Float64(issued), Float64(expiry))
end

function work_failure_dict(failure::WorkFailure)
    Dict("code" => String(failure.code), "message" => failure.message,
        "retryable" => failure.retryable, "effects_uncertain" => failure.effects_uncertain)
end

function work_failure_from(value::AbstractDict)
    code = value["code"]
    message = value["message"]
    code isa String && ncodeunits(code) <= 128 && message isa String && ncodeunits(message) <= 4096 ||
        throw(ShenScopeError(:storage, "Invalid task failure"))
    value["retryable"] isa Bool && value["effects_uncertain"] isa Bool ||
        throw(ShenScopeError(:storage, "Invalid task failure flags"))
    WorkFailure(Symbol(code), message, value["retryable"], value["effects_uncertain"])
end

function work_receipt_dict(receipt::WorkReceipt)
    Dict("execution_id" => receipt.execution_id, "attempt" => receipt.attempt,
        "phase" => String(receipt.phase), "started_at" => receipt.started_at,
        "finished_at" => receipt.finished_at, "result_sha256" => receipt.result_sha256,
        "evidence" => receipt.evidence, "hooks_started" => receipt.hooks_started, "hooks_barrier"=>receipt.hooks_barrier)
end

function work_receipt_from(value::AbstractDict)
    execution = valid_id(value["execution_id"])
    attempt = value["attempt"]
    phase = Symbol(value["phase"])
    started = value["started_at"]
    finished = get(value, "finished_at", nothing)
    result_hash = get(value, "result_sha256", nothing)
    evidence = get(value, "evidence", "")
    hooks_started = get(value,"hooks_started",false)
    hooks_barrier = get(value,"hooks_barrier",false)
    hooks_started isa Bool && hooks_barrier isa Bool || throw(ShenScopeError(:storage,"Invalid Hook execution marker"))
    attempt isa Integer && !(attempt isa Bool) && 1 <= attempt <= 32 || throw(ShenScopeError(:storage, "Invalid receipt attempt"))
    phase in (:claimed, :started, :hook_started, :succeeded, :failed, :cancelled, :interrupted, :reconciled) ||
        throw(ShenScopeError(:storage, "Invalid receipt phase"))
    started isa Real && isfinite(started) && started >= 0 || throw(ShenScopeError(:storage, "Invalid receipt start"))
    finished === nothing || finished isa Real && isfinite(finished) && finished >= started ||
        throw(ShenScopeError(:storage, "Invalid receipt finish"))
    result_hash === nothing || result_hash isa String && occursin(r"^[a-f0-9]{64}$", result_hash) ||
        throw(ShenScopeError(:storage, "Invalid receipt result hash"))
    evidence isa String && ncodeunits(evidence) <= 4096 || throw(ShenScopeError(:storage, "Receipt evidence exceeds limit"))
    phase == :hook_started && !hooks_started && throw(ShenScopeError(:storage,"Hook phase lacks its execution marker"))
    hooks_started && (!hooks_barrier || phase == :claimed) && throw(ShenScopeError(:storage,"Hook execution lacks its effect barrier"))
    WorkReceipt(execution, Int(attempt), phase, Float64(started), finished === nothing ? nothing : Float64(finished), result_hash, evidence, hooks_started, hooks_barrier)
end

function work_runtime_dict(record::WorkRecord; include_token = true)
    Dict("id" => record.spec.id, "status" => WORK_STATUS_NAMES[record.status],
        "version" => record.version, "attempts" => record.attempts, "not_before" => record.not_before,
        "lease" => record.lease === nothing ? nothing : work_lease_dict(record.lease; include_token),
        "result" => record.result, "failure" => record.failure === nothing ? nothing : work_failure_dict(record.failure),
        "receipts" => work_receipt_dict.(record.receipts), "cancel_requested" => record.cancel_requested)
end

function work_runtime_from(spec::WorkSpec, value::AbstractDict)
    value["id"] == spec.id || throw(ShenScopeError(:storage, "Task runtime identity mismatch"))
    version = value["version"]
    attempts = value["attempts"]
    not_before = value["not_before"]
    version isa Integer && !(version isa Bool) && version >= 1 && attempts isa Integer && !(attempts isa Bool) && 0 <= attempts <= spec.retry.max_attempts ||
        throw(ShenScopeError(:storage, "Invalid task runtime counters"))
    not_before isa Real && isfinite(not_before) && not_before >= 0 ||
        throw(ShenScopeError(:storage, "Invalid task scheduling timestamp"))
    status = work_status(value["status"])
    lease = value["lease"] === nothing ? nothing : work_lease_from(value["lease"])
    (status == WorkRunning) == (lease !== nothing) || throw(ShenScopeError(:storage, "Task lease/status mismatch"))
    lease === nothing || lease.generation == attempts || throw(ShenScopeError(:storage, "Task lease generation mismatch"))
    failure = value["failure"] === nothing ? nothing : work_failure_from(value["failure"])
    receipts = work_receipt_from.(value["receipts"])
    length(receipts) == attempts || throw(ShenScopeError(:storage, "Missing task attempt receipt"))
    [receipt.attempt for receipt in receipts] == collect(1:attempts) ||
        throw(ShenScopeError(:storage, "Task receipts are out of order"))
    value["cancel_requested"] isa Bool || throw(ShenScopeError(:storage, "Invalid task cancellation flag"))
    WorkRecord(spec, status, Int(version), Int(attempts), Float64(not_before), lease,
        value["result"], failure, receipts, value["cancel_requested"])
end

function work_view(record::WorkRecord; include_arguments = false, include_result = true)
    value = work_runtime_dict(record; include_token = false)
    definition = work_spec_dict(record.spec)
    include_arguments || delete!(definition, "arguments")
    value["definition"] = definition
    include_result || delete!(value, "result")
    deepcopy(value)
end
