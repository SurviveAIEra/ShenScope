function validate_work_graph(specs::AbstractVector{WorkSpec})
    1 <= length(specs) <= MAX_WORKFLOW_TASKS || throw(ShenScopeError(:tasks, "Workflow task count exceeds limits"))
    definitions = Dict{String,WorkSpec}()
    deduplication = Set{String}()
    for spec in specs
        validate_work_bindings(spec.arguments, spec.dependencies)
        haskey(definitions, spec.id) && throw(ShenScopeError(:tasks, "Duplicate task ID"))
        definitions[spec.id] = spec
        if !isempty(spec.deduplication_key)
            spec.deduplication_key in deduplication && throw(ShenScopeError(:tasks, "Duplicate workflow deduplication key"))
            push!(deduplication, spec.deduplication_key)
        end
    end
    children = Dict(id => String[] for id in keys(definitions))
    incoming = Dict{String,Int}()
    for spec in specs
        incoming[spec.id] = length(spec.dependencies)
        for dependency in spec.dependencies
            haskey(definitions, dependency) || throw(ShenScopeError(:tasks, "Task dependency does not exist"))
            push!(children[dependency], spec.id)
        end
    end
    queue = sort!([id for (id, count) in incoming if count == 0])
    order = String[]
    cursor = 1
    while cursor <= length(queue)
        id = queue[cursor]
        cursor += 1
        push!(order, id)
        for child in sort!(children[id])
            incoming[child] -= 1
            incoming[child] == 0 && push!(queue, child)
        end
    end
    length(order) == length(specs) || throw(ShenScopeError(:tasks, "Task dependencies contain a cycle"))
    order, children
end

function work_dependency_status(record::WorkRecord, tasks::AbstractDict{String,WorkRecord})
    blockers = [tasks[id].status for id in record.spec.dependencies]
    any(status -> status in (WorkFailed, WorkCancelled, WorkBlocked), blockers) && return WorkBlocked
    all(==(WorkSucceeded), blockers) ? WorkReady : WorkPending
end

function propagate_work_dependencies!(tasks::Dict{String,WorkRecord}, children::Dict{String,Vector{String}}, changed::Set{String})
    queue = sort!(collect(changed))
    cursor = 1
    while cursor <= length(queue)
        id = queue[cursor]
        cursor += 1
        for child in get(children, id, String[])
            record = tasks[child]
            record.status in (WorkPending, WorkReady, WorkBlocked) || continue
            next = work_dependency_status(record, tasks)
            next == record.status && continue
            failure = next == WorkBlocked ? WorkFailure(:dependency, "A required dependency did not succeed", false, false) : nothing
            tasks[child] = replace_work(record; status = next, failure)
            push!(changed, child)
            push!(queue, child)
        end
    end
    changed
end

function work_descendants(children::Dict{String,Vector{String}}, ids::AbstractVector{String})
    seen = Set(ids)
    queue = copy(ids)
    cursor = 1
    while cursor <= length(queue)
        id = queue[cursor]
        cursor += 1
        for child in get(children, id, String[])
            child in seen && continue
            push!(seen, child)
            push!(queue, child)
        end
    end
    sort!(collect(seen))
end
