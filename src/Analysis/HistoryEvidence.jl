struct HistoryIndexFile
    path::String
    sha256::String
    symbols::Int
    incoming_files::Int
    outgoing_files::Int
end

function history_analysis_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
    yield()
    nothing
end

function history_rank_candidates!(candidates::Vector{Dict{String,Any}}, limit::Int)
    sort!(candidates;by=entry -> (-entry["score"], entry["file"]))
    resize!(candidates, min(length(candidates), limit))
    candidates
end

function history_bound_candidate_bytes(candidates::Vector{Dict{String,Any}};maximum=3 * 1024 * 1024)
    retained = Dict{String,Any}[]
    bytes = 2
    for candidate in candidates
        size = ncodeunits(canonical(candidate)) + 1
        bytes + size <= maximum || break
        push!(retained, candidate)
        bytes += size
    end
    retained
end

struct HistoryIndexSnapshot
    root::String
    backend::String
    revision::Int
    files::Dict{String,HistoryIndexFile}
    seeds::Vector{String}
    capabilities::Dict{String,Any}
end

function history_analysis_integer(request::AbstractDict, key::String, default::Int, minimum::Int, maximum::Int)
    value = get(request, key, default)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:arguments, "Invalid history analysis " * key))
    Int(value)
end

function history_analysis_values(request::AbstractDict, key::String)
    values = get(request, key, String[])
    values isa AbstractVector && length(values) <= 128 && all(value -> value isa AbstractString, values) ||
        throw(ShenScopeError(:arguments, "History analysis " * key * " must contain at most 128 strings"))
    String.(values)
end

function history_index_snapshot(state::ProjectState, request::AbstractDict, ctx::RuntimeContext)
    state.root == ctx.root || throw(ShenScopeError(:permission, "History analysis belongs to another workspace"))
    authorize!(ctx, :read, "analysis.history", ctx.root)
    paths = history_analysis_values(request, "paths")
    symbols = history_analysis_values(request, "symbols")
    length(paths) + length(symbols) <= 128 || throw(ShenScopeError(:capacity, "Too many history analysis seeds"))
    lock(state.mutex) do
        revision = history_analysis_integer(request, "revision", state.revision, 0, typemax(Int))
        revision == state.revision || throw(ShenScopeError(:conflict, "Project revision changed before history analysis"))
        length(state.files) <= 100000 || throw(ShenScopeError(:capacity, "History join exceeds indexed-file capacity"))
        for path in paths
            git_history_path(path)
            haskey(state.files, path) || throw(ShenScopeError(:analysis, "History seed file is not indexed"))
        end
        for value in symbols
            symbol = get(state.symbols, SymbolId(value), nothing)
            symbol === nothing && throw(ShenScopeError(:analysis, "History seed symbol is not indexed"))
            push!(paths, symbol.location.file)
        end
        seeds = sort!(unique(paths))
        incoming = Dict(path => 0 for path in keys(state.files))
        outgoing = copy(incoming)
        edges = Set{Tuple{String,String}}()
        for relation in values(state.relations)
            history_analysis_checkpoint(ctx)
            relation.kind in (:calls, :imports, :inherits, :implements) || continue
            source = state.symbols[relation.src].location.file
            target = state.symbols[relation.dst].location.file
            source == target && continue
            edge = (source, target)
            edge in edges && continue
            length(edges) < 1_000_000 || throw(ShenScopeError(:capacity, "History dependency join exceeds capacity"))
            push!(edges, edge)
            outgoing[source] += 1
            incoming[target] += 1
        end
        files = Dict(path => HistoryIndexFile(path, facts.sha256, length(facts.symbols), incoming[path], outgoing[path])
            for (path, facts) in state.files if git_history_public_path(path))
        all(path -> haskey(files, path), seeds) || throw(ShenScopeError(:permission, "Protected files cannot seed history analysis"))
        HistoryIndexSnapshot(state.root, state.backend, state.revision, files, seeds,
            Dict{String,Any}(capability_dict(state.capabilities)))
    end
end

function verify_history_index(snapshot::HistoryIndexSnapshot, state::ProjectState, ctx::RuntimeContext)
    history_analysis_checkpoint(ctx)
    lock(state.mutex) do
        snapshot.root == state.root == ctx.root && snapshot.backend == state.backend && snapshot.revision == state.revision ||
            throw(ShenScopeError(:conflict, "Project index changed during history analysis; request a fresh snapshot"))
    end
    permission_decision(ctx.permissions, PermissionRequest("history-result", :read, "analysis.history", ctx.root,
        "Recheck history result delivery")) == Deny && throw(ShenScopeError(:permission, "History analysis read was revoked"))
    nothing
end

mutable struct HistoryFileStatistics
    path::String
    ordinals::Vector{Int}
    added::Int
    removed::Int
    binary_changes::Int
    change_breadth::Int
    bulk_changes::Int
end
HistoryFileStatistics(path::String) = HistoryFileStatistics(path, Int[], 0, 0, 0, 0, 0)

function history_file_statistics(snapshot::GitHistorySnapshot, ctx::RuntimeContext)
    statistics = Dict{String,HistoryFileStatistics}()
    for commit in snapshot.commits
        history_analysis_checkpoint(ctx)
        bulk = length(commit.changes) + commit.omitted_changes > snapshot.limits.bulk_threshold || commit.omitted_changes > 0
        public_count = count(change -> git_history_public_path(change.path), commit.changes)
        for change in commit.changes
            git_history_public_path(change.path) || continue
            value = get!(statistics, change.path) do; HistoryFileStatistics(change.path); end
            if bulk
                value.bulk_changes += 1
                continue
            end
            push!(value.ordinals, commit.ordinal)
            value.change_breadth += max(0, public_count - 1)
            if change.added === nothing
                value.binary_changes += 1
            else
                value.added += change.added
                value.removed += change.removed
            end
        end
    end
    statistics
end

function history_shared_ordinals(left::Vector{Int}, right::Vector{Int})
    shared = Int[]
    l = 1
    r = 1
    while l <= length(left) && r <= length(right)
        if left[l] == right[r]
            push!(shared, left[l]); l += 1; r += 1
        elseif left[l] < right[r]
            l += 1
        else
            r += 1
        end
    end
    shared
end

function history_candidate_evidence(snapshot::GitHistorySnapshot, ordinals::Vector{Int};limit=8)
    [git_history_commit_evidence(snapshot.commits[ordinal]) for ordinal in Iterators.take(ordinals, limit)]
end

function history_analysis_coverage(snapshot::GitHistorySnapshot, index::HistoryIndexSnapshot, statistics::AbstractDict)
    merge(git_history_coverage(snapshot), Dict("indexed_files" => length(index.files),
        "observed_public_files" => length(statistics),
        "historical_files_outside_index" => count(path -> !haskey(index.files, path), keys(statistics)),
        "project_revision" => index.revision, "backend" => index.backend,
        "index_matches_head" => "not_checked", "candidate_payload_limit" => 3 * 1024 * 1024,
        "backend_capabilities" => deepcopy(index.capabilities)))
end

const HISTORY_ANALYSIS_LIMITATIONS = [
    "Commit co-occurrence and line churn are observations, not proof of coupling, defects or test coverage.",
    "Only local first-parent commit history is read; side-branch commits and uncommitted changes are not independently analyzed.",
    "Shallow history, commit/output limits and excluded bulk changes limit coverage; omitted evidence is never reconstructed.",
    "Renames are recorded as deletion and addition; historical identities are not followed across renamed paths.",
    "Current indexed facts are joined by exact file path and revision; their contents are not asserted to match Git HEAD.",
    "Configured heuristic scores and support confidence are not calibrated defect probabilities."]
