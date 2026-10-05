function project_problem_editor_snapshot(manager::ProblemManager, id::AbstractString,
        ctx::RuntimeContext; allow_ask=true, maximum_items=2048)
    count = problem_integer(maximum_items, "editor problem limit", 1, 4096)
    snapshot = owned_problem_snapshot(manager, id, ctx)
    sources, statuses, configuration_current = problem_current_files(snapshot, ctx; allow_ask)
    files = Dict{String,Any}[]
    items = 0
    omitted = 0
    for file in snapshot.files
        source = get(sources, file.path, nothing)
        markers = Dict{String,Any}[]
        if source !== nothing
            for item in file.items
                if items >= count
                    omitted += 1
                    continue
                end
                # Diagnostics without a location remain in the query report;
                # assigning an arbitrary editor line would invent evidence.
                item.location === nothing && continue
                push!(markers, Dict("id" => item.id, "message" => item.message,
                    "severity" => item.severity, "code" => item.code, "source" => item.source,
                    "tags" => copy(item.tags), "range" => source_editor_range(source.source, item.location)))
                items += 1
            end
        end
        push!(files, Dict("path" => file.path, "source_sha256" => file.sha256,
            "document_version" => file.version, "freshness" => statuses[file.path],
            "publishable" => source !== nothing, "markers" => markers,
            "reported_items" => file.reported_items, "omitted_items" => file.omitted_items))
    end
    result = Dict("schema" => "shenscope.editor-problems/1", "snapshot_id" => snapshot.id,
        "snapshot_sha256" => snapshot.sha256, "provider" => snapshot.provider,
        "root_sha256" => digest(ctx.root), "session_id" => ctx.session_id,
        "revision" => snapshot.revision, "files" => files, "column_unit" => "utf16",
        "line_base" => 0, "markers" => items, "projection_omitted_items" => omitted,
        "configuration_current" => configuration_current, "coverage" => deepcopy(snapshot.coverage),
        "replace_provider_markers" => true, "complete_project_coverage" => false,
        "requires_editor_buffer_hash_check" => true)
    bounded_canonical_json(result; maximum=3*1024^2, max_depth=16, max_nodes=200_000)
    result
end
