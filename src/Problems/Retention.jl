function problem_snapshot_body(snapshot::ProblemSnapshot)
    Dict("schema" => PROBLEM_SCHEMA, "snapshot_id" => snapshot.id,
        "root_sha256" => digest(snapshot.scope[1]), "session_id" => snapshot.scope[3],
        "provider" => snapshot.provider, "revision" => snapshot.revision,
        "configuration" => deepcopy(snapshot.configuration), "files" => problem_file_dict.(snapshot.files),
        "coverage" => deepcopy(snapshot.coverage), "created_at" => snapshot.created_at,
        "diagnostics_are_producer_reports" => true, "complete_project_coverage" => false)
end

function retain_problem_snapshot!(manager::ProblemManager, ctx::RuntimeContext,
        provider::AbstractString, revision::Integer, files::Vector{ProblemFileReport};
        configuration=Dict{String,Any}[], coverage=Dict{String,Any}())
    name = problem_text(provider, "diagnostic provider", 256)
    version = problem_integer(revision, "diagnostic revision", 0, typemax(Int)-1)
    limits = manager.limits
    length(files) <= limits.maximum_files &&
        sum(length(file.items) for file in files; init=0) <= limits.maximum_items &&
        all(file -> length(file.items) <= limits.maximum_per_file, files) ||
        throw(ShenScopeError(:capacity, "Problem snapshot exceeds configured capacities"))
    length(unique(file.path for file in files)) == length(files) ||
        throw(ShenScopeError(:problems, "Problem snapshot contains repeated files"))
    configuration isa AbstractVector && length(configuration) <= 32 && coverage isa AbstractDict ||
        throw(ShenScopeError(:problems, "Invalid problem coverage or configuration"))
    for record in configuration
        problem_fields(record, ["path", "sha256"], String[], "problem configuration identity")
        problem_text(record["path"], "problem configuration path", 4096)
        record["sha256"] === nothing || problem_hash(record["sha256"], "problem configuration hash")
    end
    bounded_canonical_json(coverage; maximum=16*1024, max_depth=8, max_nodes=2048)
    authorize!(ctx, :read, "problems", ctx.root; reason="Retain an owned project diagnostic snapshot")
    workspace_source_checkpoint(ctx)
    provisional = ProblemSnapshot(string(uuid4()), problem_scope(ctx), name, version,
        deepcopy(Dict{String,Any}.(configuration)), deepcopy(sort(files; by=file -> file.path)),
        deepcopy(Dict{String,Any}(coverage)), utcstamp(), "", 0)
    encoded = bounded_canonical_json(problem_snapshot_body(provisional);
        maximum=limits.maximum_result_bytes, max_depth=24, max_nodes=200_000)
    snapshot = ProblemSnapshot(provisional.id, provisional.scope, provisional.provider, provisional.revision,
        provisional.configuration, provisional.files, provisional.coverage, provisional.created_at,
        digest(encoded), ncodeunits(encoded))
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime, "Problem manager is closed"))
        workspace_source_checkpoint(ctx)
        while length(manager.order) >= limits.maximum_snapshots ||
                manager.retained_bytes + snapshot.bytes > limits.maximum_retained_bytes
            isempty(manager.order) && throw(ShenScopeError(:capacity, "Problem snapshot cannot be retained"))
            id = popfirst!(manager.order)
            prior = pop!(manager.snapshots, id)
            manager.retained_bytes -= prior.bytes
        end
        manager.snapshots[snapshot.id] = snapshot
        push!(manager.order, snapshot.id)
        manager.retained_bytes += snapshot.bytes
    end
    snapshot
end

function owned_problem_snapshot(manager::ProblemManager, id::AbstractString, ctx::RuntimeContext)
    valid_id(problem_text(id, "problem snapshot ID", 128))
    snapshot = lock(manager.mutex) do
        get(manager.snapshots, String(id), nothing)
    end
    snapshot === nothing && throw(ShenScopeError(:problems, "Diagnostic snapshot is absent or retired"))
    snapshot.scope == problem_scope(ctx) ||
        throw(ShenScopeError(:permission, "Diagnostic snapshot belongs to another conversation or workspace"))
    snapshot
end

function list_problem_snapshots(manager::ProblemManager, ctx::RuntimeContext; limit=16)
    count = problem_integer(limit, "problem history limit", 1, 64)
    authorize!(ctx, :read, "problems", ctx.root; reason="List this conversation's diagnostic snapshots")
    snapshots = lock(manager.mutex) do
        [manager.snapshots[id] for id in reverse(manager.order) if manager.snapshots[id].scope == problem_scope(ctx)]
    end
    Dict("snapshots" => [Dict("snapshot_id" => snapshot.id, "sha256" => snapshot.sha256,
        "provider" => snapshot.provider, "revision" => snapshot.revision,
        "created_at" => snapshot.created_at, "files" => length(snapshot.files),
        "retained_items" => sum(length(file.items) for file in snapshot.files; init=0))
        for snapshot in Iterators.take(snapshots, count)],
        "retention" => "bounded_memory", "automatic_execution" => false)
end

function release_problem_snapshots!(manager::ProblemManager, ctx::RuntimeContext)
    lock(manager.mutex) do
        removed = [id for id in manager.order if manager.snapshots[id].scope == problem_scope(ctx)]
        for id in removed
            manager.retained_bytes -= manager.snapshots[id].bytes
            delete!(manager.snapshots, id)
        end
        filter!(id -> !(id in removed), manager.order)
        length(removed)
    end
end

function close_problems!(manager::ProblemManager)
    lock(manager.mutex) do
        manager.closed = true
        empty!(manager.snapshots)
        empty!(manager.order)
        manager.retained_bytes = 0
    end
    nothing
end
