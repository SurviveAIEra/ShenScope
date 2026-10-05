Base.@kwdef struct ProblemQuery
    severity::Union{Nothing,String} = nothing
    path::Union{Nothing,String} = nothing
    source::Union{Nothing,String} = nothing
    text::String = ""
    offset::Int = 0
    limit::Int = 100
end

function validate_problem_query(query::ProblemQuery)
    query.severity === nothing || query.severity in PROBLEM_SEVERITIES ||
        throw(ShenScopeError(:problems, "Invalid diagnostic severity filter"))
    query.path === nothing || problem_text(query.path, "diagnostic path filter", 4096)
    query.source === nothing || problem_text(query.source, "diagnostic source filter", 256)
    problem_text(query.text, "diagnostic text filter", 2048; empty=true)
    problem_integer(query.offset, "diagnostic page offset", 0, 100_000)
    problem_integer(query.limit, "diagnostic page limit", 1, 1000)
    query
end

function query_problem_snapshot(manager::ProblemManager, id::AbstractString, ctx::RuntimeContext;
        query=ProblemQuery(), allow_ask=true)
    validate_problem_query(query)
    snapshot = owned_problem_snapshot(manager, id, ctx)
    sources, statuses, configuration_current = problem_current_files(snapshot, ctx; allow_ask)
    items = ProjectProblem[]
    counts = Dict(level => 0 for level in PROBLEM_SEVERITIES)
    for file in snapshot.files
        haskey(sources, file.path) || continue
        for item in file.items
            counts[item.severity] += 1
            query.severity === nothing || item.severity == query.severity || continue
            query.path === nothing || item.path == query.path || continue
            query.source === nothing || item.source == query.source || continue
            isempty(query.text) || occursin(lowercase(query.text), lowercase(item.message)) || continue
            push!(items, item)
        end
    end
    sort!(items; by=problem_sort_key)
    selected = Dict{String,Any}[]
    bytes = 0
    for item in Iterators.take(Iterators.drop(items, query.offset), query.limit)
        value = problem_dict(item)
        cost = ncodeunits(canonical(value))
        bytes + cost <= 2*1024^2 || break
        push!(selected, value)
        bytes += cost
    end
    after = query.offset + length(selected)
    Dict("snapshot_id" => snapshot.id, "snapshot_sha256" => snapshot.sha256,
        "provider" => snapshot.provider, "revision" => snapshot.revision,
        "items" => selected, "total" => length(items), "offset" => query.offset,
        "next_offset" => after < length(items) ? after : nothing, "counts" => counts,
        "configuration_current" => configuration_current,
        "file_statuses" => [Dict("path" => path, "freshness" => statuses[path]) for path in sort!(collect(keys(statuses)))],
        "coverage" => deepcopy(snapshot.coverage), "complete_project_coverage" => false)
end

function compare_problem_snapshots(manager::ProblemManager, before_id::AbstractString,
        after_id::AbstractString, ctx::RuntimeContext; limit=256)
    count = problem_integer(limit, "diagnostic comparison limit", 1, 1000)
    before = owned_problem_snapshot(manager, before_id, ctx)
    after = owned_problem_snapshot(manager, after_id, ctx)
    before.provider == after.provider || throw(ShenScopeError(:problems, "Compare snapshots from the same producer"))
    authorize!(ctx, :read, "problems", ctx.root; reason="Compare two owned producer diagnostic reports")
    for path in sort!(collect(union(Set(file.path for file in before.files), Set(file.path for file in after.files))))
        absolute, _ = workspace_snapshot_path(ctx, path; must_exist=false)
        workspace_source_permission(ctx, absolute, "problems.source")
    end
    old = Dict(item.id => item for file in before.files for item in file.items)
    new = Dict(item.id => item for file in after.files for item in file.items)
    added = sort!(collect(setdiff(keys(new), keys(old))))
    removed = sort!(collect(setdiff(keys(old), keys(new))))
    unchanged = intersect(keys(old), keys(new))
    before_paths = Set(file.path for file in before.files)
    after_paths = Set(file.path for file in after.files)
    # A removed row is a change in reports, not proof the error was repaired;
    # selected files, producer settings and truncation can differ.
    Dict("before_snapshot_id" => before.id, "after_snapshot_id" => after.id,
        "before_sha256" => before.sha256, "after_sha256" => after.sha256,
        "added" => problem_dict.([new[id] for id in Iterators.take(added, count)]),
        "removed" => problem_dict.([old[id] for id in Iterators.take(removed, count)]),
        "added_total" => length(added), "removed_total" => length(removed),
        "unchanged_total" => length(unchanged), "projection_truncated" => length(added) > count || length(removed) > count,
        "same_file_selection" => before_paths == after_paths,
        "same_configuration" => before.configuration == after.configuration,
        "before_coverage" => deepcopy(before.coverage), "after_coverage" => deepcopy(after.coverage),
        "repair_independently_verified" => false)
end
