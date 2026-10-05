function project_navigation_sources(value, state::ProjectState; maximum_files=128)
    paths = Set{String}()
    visited = Ref(0)
    function collect_sources(item, depth)
        visited[] += 1
        depth <= 32 && visited[] <= 100_000 ||
            throw(ShenScopeError(:capacity, "Navigation result exceeds source-inspection capacity"))
        if item isa AbstractDict
            file = get(item, "file", nothing)
            if file isa AbstractString
                haskey(state.files, file) || throw(ShenScopeError(:stale_index, "Navigation refers to an unindexed file"))
                push!(paths, String(file))
                length(paths) <= maximum_files ||
                    throw(ShenScopeError(:capacity, "Navigation page refers to too many source files"))
            end
            for child in values(item)
                child isa Union{AbstractDict,AbstractVector} && collect_sources(child, depth+1)
            end
        elseif item isa AbstractVector
            for child in item
                collect_sources(child, depth+1)
            end
        end
    end
    collect_sources(value, 0)
    sort!(collect(paths))
end

function verify_project_navigation_page!(state::ProjectState, result::AbstractDict, ctx::RuntimeContext)
    paths = project_navigation_sources(result, state)
    versions = Dict{String,Any}[]
    bytes = 0
    for path in paths
        project_query_tick(ctx)
        absolute, _ = workspace_snapshot_path(ctx, path)
        workspace_source_permission(ctx, absolute, "project.query")
        # Rechecking selected locations does not establish freshness of every
        # dependency in the graph. Bound reads before loading another source.
        observed = stat(absolute)
        bytes+observed.size <= 32*1024^2 ||
            throw(ShenScopeError(:capacity, "Navigation page source reads exceed capacity"))
        source, facts = project_source_map(state, ctx, path)
        bytes += ncodeunits(source.source)
        bytes <= 32*1024^2 || throw(ShenScopeError(:capacity, "Navigation sources grew beyond capacity"))
        push!(versions, Dict("path" => path, "source_sha256" => facts.sha256))
    end
    project_verify_query_config(state, ctx)
    result["source_versions"] = versions
    result["selected_source_versions_verified"] = true
    result["source_check_scope"] = "selected_page_locations_before_publication"
    result["whole_project_source_versions_verified"] = false
    result
end
