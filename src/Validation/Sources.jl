function capture_validation_sources(ctx::RuntimeContext, paths, limits::ValidationLimits)
    paths isa AbstractVector && 1 <= length(paths) <= limits.maximum_files ||
        throw(ShenScopeError(:validation, "Select the bounded source files whose diagnostics may be interpreted"))
    sources = Dict{String,WorkspaceSourceSnapshot}()
    total = 0
    for path in paths
        snapshot = read_workspace_snapshot(ctx, workspace_edit_text(path, "validation source path", 4096);
            maximum_bytes=limits.maximum_file_bytes, tool="validation.source", unicode_line_separators=false)
        haskey(sources, snapshot.path) && throw(ShenScopeError(:validation, "Validation source selection repeats a file"))
        total += ncodeunits(snapshot.source.source)
        total <= limits.maximum_source_bytes || throw(ShenScopeError(:capacity, "Validation source snapshots exceed capacity"))
        sources[snapshot.path] = snapshot
    end
    sources
end

function validation_source_states(sources::Dict{String,WorkspaceSourceSnapshot}, ctx::RuntimeContext)
    rows = Dict{String,Any}[]
    for path in sort!(collect(keys(sources)))
        snapshot = sources[path]
        current = try
            verify_workspace_snapshot(snapshot, ctx; tool="validation.source")
            true
        catch cause
            cause isa ShenScopeError || rethrow()
            cause.code in (:stale_source, :path, :conflict, :permission, :cancelled) || rethrow()
            false
        end
        push!(rows, Dict("path" => path, "before_sha256" => snapshot.sha256,
            "source_version_unchanged" => current))
    end
    rows
end

function validation_problem_files(frames::Vector{ValidationDiagnosticFrame}, sources, ctx::RuntimeContext,
        cwd::String, family::String, column_unit::String, limits::ValidationLimits)
    buckets = Dict(path => ProjectProblem[] for path in keys(sources))
    invalid = 0
    outside_selection = 0
    for frame in frames
        path = validation_frame_path(ctx, cwd, frame)
        if path === nothing || !haskey(sources, path)
            outside_selection += 1
            continue
        end
        snapshot = sources[path]
        try
            location, precision = validation_frame_location(frame, snapshot.source, column_unit)
            item = project_problem(snapshot, frame.severity, frame.message;
                source="command:" * family, code=frame.code, location, semantic=false,
                metadata=Dict("output_stream" => frame.stream, "output_line" => frame.output_line,
                    "reported_column" => frame.column, "column_unit_requested" => column_unit,
                    "location_precision" => precision, "interpretation" => "bounded_untrusted_command_output"))
            push!(buckets[path], item)
        catch cause
            cause isa ShenScopeError || rethrow()
            invalid += 1
        end
    end
    files = ProblemFileReport[]
    for path in sort!(collect(keys(sources)))
        items = buckets[path]
        selected = collect(Iterators.take(items, 256))
        push!(files, problem_file_report(sources[path], selected;
            reported_items=length(items), omitted_items=length(items)-length(selected),
            status=length(items)>length(selected) ? "limited" : "reported"))
    end
    files, Dict("invalid_source_ranges" => invalid, "references_outside_selected_sources" => outside_selection)
end
