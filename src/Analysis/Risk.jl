struct RiskAnalyzer <: AbstractAnalyzer end
analyzer_name(::RiskAnalyzer) = "risk"
requirements(::RiskAnalyzer) = [:definitions, :calls, :local_git_history]

history_log_score(value::Real, reference::Real) = min(1.0, log1p(value) / log1p(reference))

function risk_candidates(snapshot::GitHistorySnapshot, index::HistoryIndexSnapshot, statistics::AbstractDict,
        request::AbstractDict, ctx::RuntimeContext)
    limit = history_analysis_integer(request, "limit", 100, 1, 1000)
    paths = isempty(index.seeds) ? sort!(collect(keys(index.files))) : index.seeds
    retained = max(1, length(snapshot.commits) - git_history_coverage(snapshot)["bulk_commits_excluded"])
    candidates = Dict{String,Any}[]
    total = 0
    for path in paths
        history_analysis_checkpoint(ctx)
        file = index.files[path]
        value = get(statistics, path, HistoryFileStatistics(path))
        frequency = length(value.ordinals)
        churn = value.added + value.removed
        breadth = frequency == 0 ? 0.0 : value.change_breadth / frequency
        components = Dict("line_churn" => history_log_score(churn, 10000),
            "change_frequency" => history_log_score(frequency, retained),
            "dependent_files" => history_log_score(file.incoming_files, 100),
            "mean_change_breadth" => history_log_score(breadth, 32))
        score = 0.35 * components["line_churn"] + 0.30 * components["change_frequency"] +
            0.25 * components["dependent_files"] + 0.10 * components["mean_change_breadth"]
        band = score >= 0.7 ? "high" : score >= 0.4 ? "medium" : "low"
        push!(candidates, Dict("file" => path, "source_sha256" => file.sha256, "indexed" => true,
            "score" => score, "review_priority" => band, "risk_kind" => "heuristic_review_priority",
            "confidence" => frequency / (frequency + 2), "confidence_kind" => "regularized_observational_support",
            "metrics" => Dict("non_bulk_commits" => frequency, "added_lines" => value.added,
                "removed_lines" => value.removed, "binary_changes" => value.binary_changes,
                "bulk_changes_excluded" => value.bulk_changes, "mean_change_breadth" => breadth,
                "incoming_files" => file.incoming_files, "outgoing_files" => file.outgoing_files,
                "indexed_symbols" => file.symbols), "components" => components,
            "evidence" => history_candidate_evidence(snapshot, value.ordinals),
            "evidence_omitted" => max(0, frequency - 8),
            "reason" => "Review priority combines observed local history with current recorded file dependencies"))
        total += 1
        length(candidates) > 2 * limit && history_rank_candidates!(candidates, limit)
    end
    history_rank_candidates!(candidates, limit)
    history_bound_candidate_bytes(candidates), total
end

function analyze(::RiskAnalyzer, state::ProjectState, request::AbstractDict, ctx::RuntimeContext)
    index = history_index_snapshot(state, request, ctx)
    history_analysis_integer(request, "limit", 100, 1, 1000)
    snapshot = git_history_snapshot(ctx;limits=git_history_limits(request))
    statistics = history_file_statistics(snapshot, ctx)
    candidates, total = risk_candidates(snapshot, index, statistics, request, ctx)
    verify_history_index(index, state, ctx)
    Dict("analyzer" => "risk", "revision" => index.revision, "seeds" => copy(index.seeds),
        "candidates" => candidates, "total_candidates" => total, "truncated" => total > length(candidates),
        "coverage" => history_analysis_coverage(snapshot, index, statistics),
        "scoring" => Dict("weights" => Dict("line_churn" => 0.35, "change_frequency" => 0.30,
            "dependent_files" => 0.25, "mean_change_breadth" => 0.10),
            "log_references" => Dict("line_churn" => 10000, "change_frequency" => "retained_non_bulk_commits",
                "dependent_files" => 100, "mean_change_breadth" => 32), "calibrated" => false),
        "limitations" => copy(HISTORY_ANALYSIS_LIMITATIONS))
end
