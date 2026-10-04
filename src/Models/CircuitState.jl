function model_circuit_clock(manager::ModelCircuitManager)
    value = manager.clock()
    value isa Real && !(value isa Bool) && isfinite(value) && value >= 0 || throw(ShenScopeError(:runtime,"Invalid model circuit monotonic clock"))
    Float64(value)
end

function model_circuit_key(provider::HTTPProvider,credentials::CredentialSnapshot,ctx::RuntimeContext)
    manager = provider.runtime.circuits
    (ctx.root,ctx.state_dir,catalog_source_id(provider),digest(manager.salt*"\0"*credentials.value))
end

function new_model_circuit_entry(policy::ModelCircuitPolicy,now::Float64)
    ModelCircuitEntry(policy,policy.enabled ? :closed : :disabled,0,0,0,nothing,nothing,0.0,policy.cooldown,Dict(),
        0,0,0,nothing,now,Dict{String,Any}[])
end

model_counter_increment(value::Int) = value == typemax(Int) ? value : value+1

function model_circuit_version_increment(value::Int)
    value < typemax(Int) || throw(ShenScopeError(:capacity,"Model circuit version capacity exhausted; clear idle history"))
    value+1
end

function model_circuit_admission_versions(entry::ModelCircuitEntry)
    # Reserve enough revisions for this acquisition and every outstanding
    # completion. Availability counters may saturate; CAS versions never do.
    required = 2*length(entry.leases)+4
    typemax(Int)-entry.revision >= required && typemax(Int)-entry.epoch >= length(entry.leases)+2 ||
        throw(ShenScopeError(:capacity,"Model circuit version capacity exhausted; clear idle history"))
    nothing
end

function model_circuit_record!(manager::ModelCircuitManager,entry::ModelCircuitEntry,event::Symbol;
        outcome=nothing,code=nothing)
    entry.revision = model_circuit_version_increment(entry.revision)
    push!(entry.history,Dict("revision"=>entry.revision,"event"=>String(event),"state"=>String(entry.state),
        "epoch"=>entry.epoch,"outcome"=>outcome === nothing ? nothing : String(outcome),
        "code"=>code === nothing ? nothing : String(code),"observed_at"=>utcstamp()))
    length(entry.history) <= manager.max_history || deleteat!(entry.history,1:length(entry.history)-manager.max_history)
    nothing
end

function model_circuit_view(entry::ModelCircuitEntry,now::Float64)
    Dict("tracked"=>true,"state"=>String(entry.state),"revision"=>entry.revision,"epoch"=>entry.epoch,
        "in_flight"=>length(entry.leases),"consecutive_failures"=>entry.consecutive_failures,
        "wait_seconds"=>entry.state == :open ? max(0.0,entry.open_until-now) : 0.0,
        "probe_available"=>entry.state == :open && now >= entry.open_until && length(entry.leases) < entry.policy.max_in_flight,
        "last_failure_code"=>entry.last_failure_code === nothing ? nothing : String(entry.last_failure_code),
        "last_outcome"=>entry.last_outcome === nothing ? nothing : String(entry.last_outcome),
        "successes"=>entry.successes,"failures"=>entry.failures,"neutral_outcomes"=>entry.neutral_outcomes,
        "policy"=>model_circuit_policy_dict(entry.policy),"history"=>deepcopy(entry.history),
        "network_probe_performed"=>false)
end

function model_circuit_empty_view(policy::ModelCircuitPolicy)
    Dict("tracked"=>false,"state"=>policy.enabled ? "closed" : "disabled","revision"=>0,"epoch"=>0,
        "in_flight"=>0,"consecutive_failures"=>0,"wait_seconds"=>0.0,"probe_available"=>false,
        "last_failure_code"=>nothing,"last_outcome"=>nothing,"successes"=>0,"failures"=>0,
        "neutral_outcomes"=>0,"policy"=>model_circuit_policy_dict(policy),"history"=>Any[],"network_probe_performed"=>false)
end

function acquire_model_circuit!(manager::ModelCircuitManager,key::ModelCircuitKey,policy::ModelCircuitPolicy)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Model circuit manager is closed"))
        now = model_circuit_clock(manager)
        sum(length(entry.leases) for entry in values(manager.entries);init=0) < manager.max_leases ||
            throw(ShenScopeError(:capacity,"Overall model inference concurrency capacity reached"))
        entry = get(manager.entries,key,nothing)
        if entry === nothing
            length(manager.entries) < manager.max_sources || throw(ShenScopeError(:capacity,"Model circuit source capacity reached"))
            entry = new_model_circuit_entry(policy,now);manager.entries[key] = entry
        end
        entry.policy == policy || throw(ShenScopeError(:config,"Model circuit policy changed without retiring its runtime"))
        model_circuit_admission_versions(entry)
        length(entry.leases) < policy.max_in_flight || throw(ShenScopeError(:capacity,"Model inference concurrency capacity reached"))
        if entry.state == :open
            now >= entry.open_until || throw(ShenScopeError(:circuit_open,"Model provider circuit is open; wait for its cooldown",true))
            entry.state = :half_open;entry.epoch = model_circuit_version_increment(entry.epoch)
            model_circuit_record!(manager,entry,:probe_ready)
        end
        if entry.state == :half_open
            any(value->value[1] == entry.epoch,values(entry.leases)) &&
                throw(ShenScopeError(:circuit_open,"A model provider recovery probe is already in flight",true))
        end
        id = string(uuid4());entry.leases[id] = (entry.epoch,entry.state == :half_open);entry.last_activity = now
        model_circuit_record!(manager,entry,:acquired)
        ModelCircuitLease(key,id,entry.epoch,entry.state == :half_open)
    end
end

function open_model_circuit!(manager::ModelCircuitManager,entry::ModelCircuitEntry,now::Float64;probe_failed=false)
    entry.cooldown = probe_failed ? min(entry.policy.maximum_cooldown,entry.cooldown*2) : entry.policy.cooldown
    entry.state = :open;entry.open_until = now+entry.cooldown
    entry.epoch = model_circuit_version_increment(entry.epoch)
    model_circuit_record!(manager,entry,:opened)
    nothing
end

function settle_model_circuit!(manager::ModelCircuitManager,lease::Union{Nothing,ModelCircuitLease},outcome::Symbol;code=nothing)
    lease === nothing && return Dict("settled"=>false,"reason"=>"disabled")
    outcome in (:success,:failure,:neutral) || throw(ArgumentError("Invalid model circuit outcome"))
    outcome == :failure && !(code in MODEL_TRANSIENT_FAILURES) &&
        throw(ArgumentError("Circuit failures must represent transient provider categories"))
    code === nothing || code isa Symbol && occursin(r"^[a-z][a-z0-9_]{0,63}$",String(code)) ||
        throw(ArgumentError("Invalid model circuit outcome category"))
    lock(manager.mutex) do
        entry = get(manager.entries,lease.key,nothing)
        entry === nothing && return Dict("settled"=>false,"reason"=>"retired")
        receipt = get(entry.leases,lease.id,nothing)
        receipt === nothing && return Dict("settled"=>false,"reason"=>"already_settled")
        receipt == (lease.epoch,lease.probe) || throw(ShenScopeError(:conflict,"Model circuit lease ownership changed"))
        delete!(entry.leases,lease.id)
        now = model_circuit_clock(manager);entry.last_activity = now
        if outcome == :success
            entry.successes = model_counter_increment(entry.successes)
        elseif outcome == :failure
            entry.failures = model_counter_increment(entry.failures)
        else
            entry.neutral_outcomes = model_counter_increment(entry.neutral_outcomes)
        end
        current = lease.epoch == entry.epoch
        current && (entry.last_outcome = outcome)
        if current && !entry.policy.enabled
            outcome == :failure && (entry.last_failure_code = code)
            outcome == :success && (entry.last_failure_code = nothing)
        end
        if current && entry.policy.enabled
            if outcome == :success
                entry.consecutive_failures = 0;entry.last_failure_time = nothing;entry.last_failure_code = nothing
                if lease.probe
                    entry.state = :closed;entry.open_until = 0.0;entry.cooldown = entry.policy.cooldown
                    entry.epoch = model_circuit_version_increment(entry.epoch)
                    model_circuit_record!(manager,entry,:recovered)
                end
            elseif outcome == :failure
                if entry.last_failure_time === nothing || now-entry.last_failure_time > entry.policy.failure_window
                    entry.consecutive_failures = 0
                end
                entry.consecutive_failures = model_counter_increment(entry.consecutive_failures)
                entry.last_failure_time = now;entry.last_failure_code = code
                (lease.probe || entry.consecutive_failures >= entry.policy.failure_threshold) &&
                    open_model_circuit!(manager,entry,now;probe_failed=lease.probe)
            elseif lease.probe
                # A canceled/denied probe offers no availability evidence.
                # Keep the expired-open state so a later explicit request can
                # acquire another single probe without a background request.
                entry.state = :open;entry.open_until = now
                entry.epoch = model_circuit_version_increment(entry.epoch)
                model_circuit_record!(manager,entry,:probe_inconclusive)
            end
        end
        model_circuit_record!(manager,entry,current ? :settled : :stale_settlement;outcome,code)
        Dict("settled"=>true,"current_epoch"=>current,"health"=>model_circuit_view(entry,now))
    end
end
