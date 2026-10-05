function sarif_result_problems!(state::SarifParseContext, value, buckets, counters;
        maximum_diagnostics=512, result_ordinal=1)
    result = sarif_object(value, "SARIF result")
    sarif_result_inactive(result, state) && return
    kind = get(result, "kind", "fail")
    kind in ("notApplicable", "pass", "fail", "review", "open", "informational") ||
        throw(ShenScopeError(:sarif, "Invalid SARIF result kind"))
    if kind in ("pass", "notApplicable")
        sarif_omit!(state, "non_problem_results")
        return
    end
    id, rule = sarif_rule(state, result)
    message, resolution = sarif_message(state, result, rule)
    severity = sarif_severity(result, rule)
    locations = sarif_array(get(result, "locations", Any[]), "SARIF result locations", state.limits.maximum_locations_per_result)
    if isempty(locations)
        sarif_omit!(state, "results_without_source_locations")
        return
    end
    for (location_ordinal, raw) in enumerate(locations)
        workspace_source_checkpoint(state.context)
        if counters["retained"] >= maximum_diagnostics
            sarif_omit!(state, "diagnostic_capacity")
            continue
        end
        location = try
            sarif_source_location(state, raw)
        catch cause
            cause isa ShenScopeError || rethrow()
            cause.code in (:sarif, :path, :permission, :language_uri, :language_config, :language_protocol,
                :graph_query, :graph, :source_position) || rethrow()
            sarif_omit!(state, "invalid_or_unavailable_locations")
            continue
        end
        if location === nothing
            sarif_omit!(state, "locations_outside_selected_sources")
            continue
        end
        source, range, precision = location
        items = buckets[source.path]
        if length(items) >= 256
            sarif_omit!(state, "per_file_diagnostic_capacity")
            continue
        end
        problem = project_problem(source, severity, message; source=state.producer,
            code=id, location=range, semantic=false,
            metadata=Dict("format" => "sarif_2_1_0", "result_kind" => kind,
                "result_ordinal" => result_ordinal, "location_ordinal" => location_ordinal,
                "location_precision" => precision, "column_kind" => state.column_kind,
                "message_resolution" => resolution, "baseline_state" => get(result, "baselineState", nothing),
                "report_producer_authenticated" => false, "source_manifest_origin" => "explicit_caller_selection",
                "automatic_fix_execution" => false))
        push!(items, problem)
        counters["retained"] += 1
    end
end

function parse_sarif_problems(document, sources::Dict{String,WorkspaceSourceSnapshot},
        ctx::RuntimeContext; limits=SarifLimits(), maximum_diagnostics=512)
    validate_sarif_limits(limits)
    problem_integer(maximum_diagnostics, "SARIF diagnostic limit", 1, 4096)
    document = sarif_object(document, "SARIF document")
    get(document, "version", nothing) == SARIF_VERSION || throw(ShenScopeError(:sarif, "Only SARIF 2.1.0 is supported"))
    runs = sarif_array(get(document, "runs", nothing), "SARIF runs", limits.maximum_runs)
    buckets = Dict(path => ProjectProblem[] for path in keys(sources))
    counters = Dict("retained" => 0)
    summaries = Dict{String,Any}[]
    reported = 0
    for (run_ordinal, run) in enumerate(runs)
        workspace_source_checkpoint(ctx)
        state = sarif_run_context(ctx, sources, run, limits)
        results = sarif_array(get(state.run, "results", Any[]), "SARIF results", limits.maximum_results)
        reported += length(results)
        reported <= limits.maximum_results || throw(ShenScopeError(:capacity, "Combined SARIF result count exceeds capacity"))
        failures = 0
        for (ordinal, result) in enumerate(results)
            workspace_source_checkpoint(ctx)
            try
                sarif_result_problems!(state, result, buckets, counters; maximum_diagnostics, result_ordinal=ordinal)
            catch cause
                cause isa ShenScopeError || rethrow()
                cause.code in (:sarif, :workspace_edit, :language_config, :language_protocol,
                    :problems, :capacity, :source_location) || rethrow()
                failures += 1
            end
        end
        push!(summaries, Dict("run_ordinal" => run_ordinal, "producer" => state.producer,
            "driver_rule_count" => length(state.rules), "driver_rules_sha256" => sarif_rule_catalog_sha256(state),
            "column_kind" => state.column_kind, "reported_results" => length(results),
            "invalid_results" => failures, "omissions" => deepcopy(state.omissions),
            "automatic_fixes_supported" => false, "related_locations_interpreted" => false))
    end
    files = [problem_file_report(sources[path], buckets[path]) for path in sort!(collect(keys(sources)))]
    files, Dict("runs" => summaries, "reported_results" => reported,
        "retained_diagnostics" => counters["retained"], "selected_sources" => length(sources),
        "complete_project_coverage" => false, "all_sarif_features_supported" => false,
        "producer_source_versions_independently_verified" => false)
end
