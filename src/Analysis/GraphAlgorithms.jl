function strongly_connected_groups(forward::Dict{String,Set{String}}, reverse::Dict{String,Set{String}};
        checkpoint=()->nothing, max_edges=1_000_000)
    Set(keys(forward)) == Set(keys(reverse)) || throw(ShenScopeError(:analysis_graph, "Graph adjacency keys disagree"))
    count = 0
    for (source, targets) in forward
        checkpoint()
        for target in targets
            count += 1
            count <= max_edges || throw(ShenScopeError(:capacity, "Graph edge capacity exceeded"))
            haskey(reverse, target) && source in reverse[target] ||
                throw(ShenScopeError(:analysis_graph, "Graph reverse adjacency is inconsistent"))
        end
    end
    for (target, sources) in reverse
        checkpoint()
        all(source -> haskey(forward, source) && target in forward[source], sources) ||
            throw(ShenScopeError(:analysis_graph, "Graph forward adjacency is inconsistent"))
    end
    visited = Set{String}()
    order = String[]
    for seed in sort!(collect(keys(forward)))
        seed in visited && continue
        stack = Tuple{String,Bool}[(seed, false)]
        while !isempty(stack)
            checkpoint()
            node, finish = pop!(stack)
            if finish
                push!(order, node)
                continue
            end
            node in visited && continue
            push!(visited, node)
            push!(stack, (node, true))
            for next in sort!(collect(forward[node]);rev=true)
                next in visited || push!(stack, (next, false))
            end
        end
    end
    empty!(visited)
    groups = Vector{String}[]
    for seed in Iterators.reverse(order)
        seed in visited && continue
        component = String[]
        queue = [seed]
        while !isempty(queue)
            checkpoint()
            node = pop!(queue)
            node in visited && continue
            push!(visited, node)
            push!(component, node)
            append!(queue, sort!(collect(reverse[node]);rev=true))
        end
        push!(groups, sort!(component))
    end
    sort!(groups;by=first)
end

function dependency_layers(dependencies::Dict{String,Set{String}};checkpoint=()->nothing)
    dependents = Dict(key => Set{String}() for key in keys(dependencies))
    remaining = Dict(key => length(values) for (key, values) in dependencies)
    for (node, values) in dependencies
        checkpoint()
        node in values && throw(ShenScopeError(:analysis_graph, "Condensed graph contains a self-dependency"))
        for dependency in values
            haskey(dependents, dependency) || throw(ShenScopeError(:analysis_graph, "Dependency target is missing"))
            push!(dependents[dependency], node)
        end
    end
    ready = sort!([key for (key, count) in remaining if count == 0])
    layers = Vector{String}[]
    processed = 0
    while !isempty(ready)
        checkpoint()
        push!(layers, ready)
        next = String[]
        for node in ready
            processed += 1
            for dependent in sort!(collect(dependents[node]))
                remaining[dependent] -= 1
                remaining[dependent] == 0 && push!(next, dependent)
            end
        end
        ready = sort!(next)
    end
    processed == length(dependencies) || throw(ShenScopeError(:analysis_graph, "Condensed dependency graph is cyclic"))
    layers
end
