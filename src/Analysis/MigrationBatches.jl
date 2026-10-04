function migration_plan(graph::MigrationGraph, options::MigrationOptions, ctx::RuntimeContext)
    checkpoint = () -> history_analysis_checkpoint(ctx)
    groups = strongly_connected_groups(graph.forward, graph.reverse;checkpoint, max_edges=options.max_relations)
    ids = Dict{String,String}()
    members = Dict{String,Vector{String}}()
    for group in groups
        checkpoint()
        id = "batch-" * digest(canonical(group))[1:24]
        members[id] = group
        for path in group; ids[path] = id; end
    end
    dependencies = Dict(id => Set{String}() for id in keys(members))
    for ((source, target), evidence) in graph.dependencies
        checkpoint()
        caller = ids[source]
        callee = ids[target]
        caller == callee && continue
        if options.order == :dependency_first
            push!(dependencies[caller], callee)
        else
            push!(dependencies[callee], caller)
        end
    end
    layers = dependency_layers(dependencies;checkpoint)
    batches = MigrationBatch[]
    for (layer, values) in enumerate(layers)
        # SCC hashes identify batches; paths determine human-facing tie order.
        for id in sort!(values;by=id -> first(members[id]))
            checkpoint()
            push!(batches, MigrationBatch(id, members[id], sort!(collect(dependencies[id])), length(members[id]) > 1, layer))
        end
    end
    identity = Dict("workspace" => digest(ctx.root), "fingerprint" => graph.snapshot.fingerprint,
        "revision" => graph.snapshot.revision, "seed_files" => sort!(collect(graph.seeds)),
        "seed_ids" => sort!(collect(graph.snapshot.seed_ids)),
        "selected_symbol_ids" => sort!(collect(keys(graph.snapshot.symbols))),
        "snapshot_truncated" => graph.snapshot.data["truncated"],
        "change_kind" => String(options.change_kind), "order" => String(options.order),
        "minimum_confidence" => options.minimum_confidence, "depth" => options.max_depth,
        "batches" => [Dict("id" => batch.id, "files" => batch.files, "dependencies" => batch.dependencies) for batch in batches])
    MigrationPlan(digest(canonical(identity)), graph, options, batches, count(batch -> batch.cycle, batches))
end
