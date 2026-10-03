const MAX_WORK_RESULT_BYTES = 8 * 1024 * 1024
const MAX_WORK_ARTIFACT_BYTES = 64 * 1024 * 1024
const WORK_RESULT_REFERENCE = "shenscope.task.result.v1"

function serialize_work_result(value)
    work_json_value(value; max_string_bytes = MAX_WORK_RESULT_BYTES, credentials = true)
    serialized = canonical(value)
    ncodeunits(serialized) <= MAX_WORK_RESULT_BYTES || throw(ShenScopeError(:capacity, "Task result exceeds eight MiB"))
    serialized
end

function work_artifact_dir(workflow::Workflow)
    joinpath(dirname(workflow.journal.path), workflow.id * ".results")
end

function work_result_reference(value)
    value isa AbstractDict && get(value, "format", nothing) == WORK_RESULT_REFERENCE
end

function work_result_path(workflow::Workflow, sha::AbstractString)
    occursin(r"^[a-f0-9]{64}$", sha) || throw(ShenScopeError(:storage, "Invalid task result digest"))
    joinpath(work_artifact_dir(workflow), sha * ".json")
end

function store_work_result_locked!(workflow::Workflow, serialized::String)
    if ncodeunits(serialized) <= MAX_WORK_ARGUMENT_BYTES
        value = parsejson(serialized)
        # A user result cannot impersonate an internal artifact descriptor.
        work_result_reference(value) || return value
    end
    sha = digest(serialized)
    path = work_result_path(workflow, sha)
    directory = dirname(path)
    islink(directory) && throw(ShenScopeError(:storage, "Task artifact directory cannot be a symlink"))
    if ispath(path)
        isfile(path) && !islink(path) && filesize(path) == ncodeunits(serialized) &&
            digest(read(path, String)) == sha || throw(ShenScopeError(:storage, "Existing task artifact is corrupt"))
    else
        used = 0
        entries = isdir(directory) ? readdir(directory) : String[]
        length(entries) <= MAX_WORKFLOW_TASKS * 32 || throw(ShenScopeError(:capacity, "Task artifact count exceeds capacity"))
        for entry in entries
            candidate = joinpath(directory, entry)
            islink(candidate) && throw(ShenScopeError(:storage, "Task artifact cannot be a symlink"))
            isfile(candidate) || throw(ShenScopeError(:storage, "Unexpected task artifact entry"))
            used += filesize(candidate)
        end
        used + ncodeunits(serialized) <= MAX_WORK_ARTIFACT_BYTES || throw(ShenScopeError(:capacity, "Workflow result storage capacity reached"))
        atomic_write(path, serialized)
    end
    Dict("format" => WORK_RESULT_REFERENCE, "sha256" => sha, "bytes" => ncodeunits(serialized))
end

function materialize_work_result(workflow::Workflow, record::WorkRecord, ctx::RuntimeContext)
    check_workflow_scope(workflow, ctx)
    authorize!(ctx, :read, "tasks.result", ctx.root)
    record.status == WorkSucceeded || throw(ShenScopeError(:tasks, "Task has no successful result"))
    value = record.result
    expected = current_work_receipt(record).result_sha256
    expected === nothing && throw(ShenScopeError(:storage, "Task receipt has no result digest"))
    if work_result_reference(value)
        value["sha256"] == expected || throw(ShenScopeError(:storage, "Task artifact/receipt mismatch"))
        bytes = value["bytes"]
        bytes isa Integer && !(bytes isa Bool) && 1 <= bytes <= MAX_WORK_RESULT_BYTES ||
            throw(ShenScopeError(:storage, "Invalid task artifact size"))
        path = work_result_path(workflow, expected)
        !islink(dirname(path)) && !islink(path) && isfile(path) && filesize(path) == bytes ||
            throw(ShenScopeError(:storage, "Task result artifact is missing or has changed"))
        serialized = read(path, String)
        digest(serialized) == expected || throw(ShenScopeError(:storage, "Task result checksum mismatch"))
        return parsejson(serialized)
    end
    digest(canonical(value)) == expected || throw(ShenScopeError(:storage, "Inline task result checksum mismatch"))
    deepcopy(value)
end

function validate_work_bindings(value, dependencies::Vector{String})
    if value isa AbstractDict
        if haskey(value, "\$task_result")
            all(key -> key in ("\$task_result", "path"), keys(value)) ||
                throw(ShenScopeError(:tasks, "Result binding contains unknown fields"))
            value["\$task_result"] in dependencies || throw(ShenScopeError(:tasks, "Result binding must name a direct dependency"))
            path = get(value, "path", Any[])
            path isa AbstractVector && length(path) <= 32 &&
                all(part -> part isa AbstractString || part isa Integer && !(part isa Bool) && part >= 1, path) ||
                throw(ShenScopeError(:tasks, "Result binding path is invalid"))
        else
            foreach(child -> validate_work_bindings(child, dependencies), values(value))
        end
    elseif value isa AbstractVector
        foreach(child -> validate_work_bindings(child, dependencies), value)
    end
    nothing
end

function resolve_work_arguments(workflow::Workflow, record::WorkRecord, ctx::RuntimeContext)
    dependencies = lock(workflow.mutex) do
        store_lock(workflow.journal.path) do
            read_workflow_locked!(workflow, ctx)
            Dict(id => deepcopy(workflow.tasks[id]) for id in record.spec.dependencies)
        end
    end
    cache = Dict{String,Any}()
    function resolve(value)
        if value isa AbstractDict && haskey(value, "\$task_result")
            id = value["\$task_result"]
            haskey(dependencies, id) || throw(ShenScopeError(:tasks, "Undeclared result dependency"))
            selected = get!(cache, id) do
                materialize_work_result(workflow, dependencies[id], ctx)
            end
            for part in get(value, "path", Any[])
                if selected isa AbstractDict && part isa AbstractString && haskey(selected, part)
                    selected = selected[part]
                elseif selected isa AbstractVector && part isa Integer && 1 <= part <= length(selected)
                    selected = selected[part]
                else
                    throw(ShenScopeError(:tasks, "Dependency result path does not exist"))
                end
            end
            return deepcopy(selected)
        elseif value isa AbstractDict
            return Dict{String,Any}(key => resolve(child) for (key, child) in value)
        elseif value isa AbstractVector
            return Any[resolve(child) for child in value]
        end
        value
    end
    arguments = resolve(record.spec.arguments)
    ncodeunits(canonical(arguments)) <= MAX_WORK_ARGUMENT_BYTES ||
        throw(ShenScopeError(:capacity, "Resolved task arguments exceed capacity"))
    arguments
end
