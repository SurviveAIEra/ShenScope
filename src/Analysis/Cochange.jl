struct GitCochangeAnalyzer <: AbstractAnalyzer end
analyzer_name(::GitCochangeAnalyzer) = "git_cochange"
requirements(::GitCochangeAnalyzer) = [:definitions, :local_git_history]

function cochange_candidates(snapshot::GitHistorySnapshot, index::HistoryIndexSnapshot, statistics::AbstractDict,
        request::AbstractDict, ctx::RuntimeContext)
    limit = history_analysis_integer(request, "limit", 100, 1, 1000)
    minimum = history_analysis_integer(request, "minimum_support", 2, 1, 512)
    seeds = Set(index.seeds)
    candidates = Dict{String,Any}[]
    total = 0
    for path in sort!(collect(keys(statistics)))
        history_analysis_checkpoint(ctx)
        path in seeds && continue
        haskey(index.files, path) || continue
        target = statistics[path]
        isempty(target.ordinals) && continue
        associations = Dict{String,Any}[]
        for seed in index.seeds
            source = get(statistics, seed, nothing)
            source === nothing && continue
            joint = history_shared_ordinals(source.ordinals, target.ordinals)
            length(joint) >= minimum || continue
            support = length(joint)
            dice = 2 * support / (length(source.ordinals) + length(target.ordinals))
            confidence = support / (support + 2)
            push!(associations, Dict("seed" => seed, "seed_sha256" => index.files[seed].sha256,
                "joint_commits" => support, "seed_commits" => length(source.ordinals),
                "candidate_commits" => length(target.ordinals), "conditional_frequency" => support / length(source.ordinals),
                "dice" => dice, "score" => dice * confidence, "confidence" => confidence,
                "evidence" => history_candidate_evidence(snapshot, joint), "evidence_omitted" => max(0, support - 8)))
        end
        isempty(associations) && continue
        sort!(associations;by=entry -> (-entry["score"], -entry["joint_commits"], entry["seed"]))
        association_count = length(associations)
        resize!(associations, min(association_count, 8))
        best = first(associations)
        file = index.files[path]
        push!(candidates, Dict("file" => path, "source_sha256" => file.sha256, "indexed" => true,
            "score" => best["score"], "confidence" => best["confidence"],
            "confidence_kind" => "regularized_observational_support", "joint_commits" => best["joint_commits"],
            "evidence" => deepcopy(best["evidence"]), "associations" => associations,
            "association_count" => association_count, "associations_omitted" => association_count - length(associations),
            "reason" => "Changed with an indexed seed in retained non-bulk first-parent commits"))
        total += 1
        length(candidates) > 2 * limit && history_rank_candidates!(candidates, limit)
    end
    history_rank_candidates!(candidates, limit)
    history_bound_candidate_bytes(candidates), total
end

function analyze(::GitCochangeAnalyzer, state::ProjectState, request::AbstractDict, ctx::RuntimeContext)
    index = history_index_snapshot(state, request, ctx)
    isempty(index.seeds) && throw(ShenScopeError(:arguments, "Git co-change analysis requires indexed paths or symbols"))
    history_analysis_integer(request, "limit", 100, 1, 1000)
    history_analysis_integer(request, "minimum_support", 2, 1, 512)
    snapshot = git_history_snapshot(ctx;limits=git_history_limits(request))
    statistics = history_file_statistics(snapshot, ctx)
    candidates, total = cochange_candidates(snapshot, index, statistics, request, ctx)
    verify_history_index(index, state, ctx)
    Dict("analyzer" => "git_cochange", "revision" => index.revision, "seeds" => copy(index.seeds),
        "candidates" => candidates, "total_candidates" => total, "truncated" => total > length(candidates),
        "coverage" => history_analysis_coverage(snapshot, index, statistics),
        "scoring" => Dict("formula" => "dice * joint_commits / (joint_commits + 2)",
            "multi_seed" => "maximum association", "prior_support" => 2,
            "minimum_support" => get(request, "minimum_support", 2)),
        "limitations" => copy(HISTORY_ANALYSIS_LIMITATIONS))
end
