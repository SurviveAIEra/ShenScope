function migration_relation_evidence(graph::MigrationGraph, relation_id::String)
    relation = graph.snapshot.relations[relation_id]
    Dict("relation_id" => relation_id, "kind" => relation["kind"], "confidence" => relation["confidence"],
        "provenance" => relation["provenance"], "source" => relation["src"], "target" => relation["dst"],
        "location" => deepcopy(relation["location"]))
end

function migration_batch_view(plan::MigrationPlan, batch::MigrationBatch)
    graph = plan.graph
    selected = Set(batch.files)
    dependencies = Dict{String,Any}[]
    dependency_count = 0
    for key in sort!(collect(keys(graph.dependencies)))
        source, target = key
        source in selected || target in selected || continue
        dependency_count += 1
        length(dependencies) < 64 || continue
        value = graph.dependencies[key]
        push!(dependencies, Dict("source_file" => source, "target_file" => target,
            "internal" => source in selected && target in selected, "relation_count" => length(value.relation_ids),
            "minimum_confidence" => value.minimum_confidence, "kinds" => sort!(collect(value.kinds)),
            "evidence" => [migration_relation_evidence(graph, id) for id in Iterators.take(value.relation_ids, 8)],
            "evidence_omitted" => max(0, length(value.relation_ids) - 8)))
    end
    sort!(dependencies;by=value -> (value["source_file"], value["target_file"]))
    tests = Dict{String,Any}[]
    test_count = 0
    files = Dict{String,Any}[]
    for path in batch.files
        file = graph.files[path]
        push!(files, Dict("path" => path, "sha256" => file.sha256, "seed" => path in graph.seeds,
            "selected_symbols" => length(file.symbol_ids)))
        for id in file.test_ids
            test_count += 1
            length(tests) < 32 && push!(tests, deepcopy(graph.snapshot.symbols[id]))
        end
    end
    Dict("id" => batch.id, "layer" => batch.layer, "files" => files, "depends_on" => copy(batch.dependencies),
        "atomic_group" => batch.cycle, "manual_review_required" => true,
        "compatibility_review_required" => plan.options.change_kind in (:signature, :rename, :remove, :move),
        "dependencies" => dependencies, "dependency_count" => dependency_count,
        "dependencies_omitted" => dependency_count - length(dependencies), "test_candidates" => tests,
        "test_candidates_omitted" => test_count - length(tests),
        "reason" => batch.cycle ? "Recorded file dependency cycle requires one coordinated review group" :
            "Ordered against recorded inter-file dependencies under the chosen strategy")
end

function migration_plan_view(plan::MigrationPlan, ctx::RuntimeContext)
    steps = Dict{String,Any}[]
    bytes = 2
    for batch in Iterators.take(plan.batches, plan.options.step_limit)
        history_analysis_checkpoint(ctx)
        view = migration_batch_view(plan, batch)
        size = ncodeunits(canonical(view)) + 1
        bytes + size <= 3 * 1024 * 1024 || break
        bytes += size
        push!(steps, view)
    end
    graph = plan.graph
    partial = graph.snapshot.data["truncated"] || length(steps) < length(plan.batches)
    Dict("analyzer" => "migration", "plan_id" => plan.id, "revision" => graph.snapshot.revision,
        "fingerprint" => graph.snapshot.fingerprint, "change_kind" => String(plan.options.change_kind),
        "order" => String(plan.options.order), "seed_files" => sort!(collect(graph.seeds)), "steps" => steps,
        "total_steps" => length(plan.batches), "omitted_steps" => length(plan.batches) - length(steps),
        "cycle_groups" => plan.cycle_count, "truncated" => partial,
        "status" => partial ? "partial_proposal" : "review_proposal", "human_review_required" => true,
        "writes_performed" => false, "tests_executed" => false, "execution_registered" => false,
        "coverage" => Dict("backend" => graph.snapshot.data["backend"], "capabilities" => deepcopy(graph.snapshot.data["coverage"]),
            "selected_files" => length(graph.files), "selected_symbols" => length(graph.snapshot.symbols),
            "selected_relations" => length(graph.snapshot.relations), "file_dependencies" => length(graph.dependencies),
            "scope" => graph.snapshot.data["scope"], "depth" => plan.options.max_depth,
            "minimum_confidence" => plan.options.minimum_confidence,
            "relations_excluded_by_confidence" => graph.excluded_confidence,
            "ignored_relation_kinds" => graph.ignored_relations, "candidate_payload_limit" => 3 * 1024 * 1024),
        "limitations" => ["This is a review proposal over recorded facts; it does not apply edits, schedule tasks or validate a migration.",
            "Unknown/dynamic/external dependencies and bounded neighborhoods can omit affected code.",
            "Dependency order alone cannot preserve API compatibility; signatures, renames, moves and removals need explicit compatibility review.",
            "Cycle groups require coordinated review; an atomic group is not a filesystem transaction.",
            "Test-named symbols are candidates only; no coverage or executed test evidence is attached."])
end
