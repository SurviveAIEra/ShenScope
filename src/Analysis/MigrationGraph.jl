function migration_graph(state::ProjectState, request::AbstractDict, options::MigrationOptions, ctx::RuntimeContext)
    paths = history_analysis_values(request, "paths")
    symbols = history_analysis_values(request, "symbols")
    1 <= length(paths) + length(symbols) <= 128 || throw(ShenScopeError(:arguments, "Migration requires at most 128 indexed path or symbol seeds"))
    authorize!(ctx, :read, "analysis.migration", ctx.root;reason="Plan a migration using recorded project dependencies")
    arguments = Dict{String,Any}("paths" => paths, "symbols" => symbols, "direction" => "reverse",
        "max_symbols" => options.max_symbols, "max_relations" => options.max_relations, "max_depth" => options.max_depth)
    snapshot = analyzer_graph_snapshot(state, arguments, ctx)
    expected = history_analysis_integer(request, "revision", snapshot.revision, 0, typemax(Int))
    expected == snapshot.revision || throw(ShenScopeError(:conflict, "Migration project revision is stale"))
    hashes = Dict(String(file["path"]) => String(file["sha256"]) for file in snapshot.data["files"])
    length(hashes) <= options.max_files || throw(ShenScopeError(:capacity, "Migration neighborhood exceeds file capacity; narrow the seeds"))
    files = Dict(path => MigrationFile(path, hash, String[], String[]) for (path, hash) in hashes)
    seeds = Set{String}()
    for id in sort!(collect(keys(snapshot.symbols)))
        history_analysis_checkpoint(ctx)
        symbol = snapshot.symbols[id]
        path = symbol["location"]["file"]
        haskey(files, path) || throw(ShenScopeError(:analysis_graph, "Migration symbol has no file evidence"))
        push!(files[path].symbol_ids, id)
        is_test_symbol(symbol) && push!(files[path].test_ids, id)
        id in snapshot.seed_ids && push!(seeds, path)
    end
    forward = Dict(path => Set{String}() for path in keys(files))
    reverse = Dict(path => Set{String}() for path in keys(files))
    dependencies = Dict{Tuple{String,String},MigrationDependency}()
    excluded = 0
    ignored = 0
    for id in sort!(collect(keys(snapshot.relations)))
        history_analysis_checkpoint(ctx)
        relation = snapshot.relations[id]
        if !(relation["kind"] in ("calls", "imports", "inherits", "implements", "references"))
            ignored += 1
            continue
        end
        if relation["confidence"] < options.minimum_confidence
            excluded += 1
            continue
        end
        source = snapshot.symbols[relation["src"]]["location"]["file"]
        target = snapshot.symbols[relation["dst"]]["location"]["file"]
        source == target && continue
        key = (source, target)
        dependency = get!(dependencies, key) do
            MigrationDependency(source, target, String[], Set{String}(), 1.0)
        end
        push!(dependency.relation_ids, id)
        push!(dependency.kinds, relation["kind"])
        dependency.minimum_confidence = min(dependency.minimum_confidence, relation["confidence"])
        push!(forward[source], target)
        push!(reverse[target], source)
    end
    MigrationGraph(snapshot, files, seeds, forward, reverse, dependencies, excluded, ignored)
end
