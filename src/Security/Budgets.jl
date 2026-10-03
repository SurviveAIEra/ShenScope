Base.@kwdef struct BudgetLimits
    max_steps::Int = 100
    max_tokens::Int = 1_000_000
    max_cost::Float64 = 10.0
    max_seconds::Float64 = 3600.0
end

struct Reservation
    tokens::Int
    cost::Float64
end

mutable struct BudgetLedger
    limits::BudgetLimits
    steps::Int
    tokens::Int
    cost::Float64
    reported_cost::Float64
    reservations::Dict{String,Reservation}
    started_ns::UInt64
    mutex::ReentrantLock
end
function BudgetLedger(limits=BudgetLimits())
    limits.max_steps > 0 && limits.max_tokens > 0 && limits.max_cost >= 0 &&
        isfinite(limits.max_cost) && limits.max_seconds > 0 ||
        throw(ArgumentError("Invalid budget limits"))
    return BudgetLedger(limits,0,0,0.0,0.0,Dict{String,Reservation}(),time_ns(),ReentrantLock())
end

function check_budget(b::BudgetLedger)
    (time_ns()-b.started_ns)/1e9 <= b.limits.max_seconds ||
        throw(ShenScopeError(:budget, "Wall-clock budget exhausted"))
    b.tokens <= b.limits.max_tokens || throw(ShenScopeError(:budget,"Token budget exhausted"))
    b.cost <= b.limits.max_cost || throw(ShenScopeError(:budget,"Cost budget exhausted"))
end

function reserve!(b::BudgetLedger, tokens::Int, cost::Real=0.0)
    tokens >= 0 && isfinite(cost) && cost >= 0 || throw(ArgumentError("Invalid reservation"))
    return lock(b.mutex) do
        check_budget(b)
        reserved_tokens = sum(r.tokens for r in values(b.reservations); init=0)
        reserved_cost = sum(r.cost for r in values(b.reservations); init=0.0)
        b.steps < b.limits.max_steps || throw(ShenScopeError(:budget,"Step budget exhausted"))
        tokens <= b.limits.max_tokens-b.tokens-reserved_tokens ||
            throw(ShenScopeError(:budget,"Request exceeds remaining token budget"))
        cost <= b.limits.max_cost-b.cost-reserved_cost ||
            throw(ShenScopeError(:budget,"Request exceeds remaining cost budget"))
        id = string(uuid4())
        b.reservations[id] = Reservation(tokens, Float64(cost))
        b.steps += 1
        return id
    end
end

function settle!(b::BudgetLedger, id::String, usage::Usage)
    usage.input_tokens >= 0 && usage.output_tokens >= 0 && usage.cost >= 0 &&
        isfinite(usage.cost) || throw(ShenScopeError(:protocol,"Invalid reported usage"))
    lock(b.mutex) do
        haskey(b.reservations,id) || throw(ShenScopeError(:budget,"Unknown or settled reservation"))
        delete!(b.reservations,id)
        b.tokens += usage.input_tokens + usage.output_tokens
        b.cost += usage.cost
        usage.source == :reported && (b.reported_cost += usage.cost)
    end
    return nothing
end

function release!(b::BudgetLedger, id::String)
    lock(b.mutex) do
        delete!(b.reservations,id)
    end
end

function budget_status(b::BudgetLedger)
    return lock(b.mutex) do
        Dict("steps"=>b.steps,"tokens"=>b.tokens,"cost"=>b.cost,
            "reported_cost"=>b.reported_cost,"reserved_tokens"=>sum(r.tokens for r in values(b.reservations);init=0),
            "reserved_cost"=>sum(r.cost for r in values(b.reservations);init=0.0),
            "elapsed_seconds"=>(time_ns()-b.started_ns)/1e9,
            "limits"=>Dict("max_steps"=>b.limits.max_steps,"max_tokens"=>b.limits.max_tokens,
                "max_cost"=>b.limits.max_cost,"max_seconds"=>b.limits.max_seconds))
    end
end
