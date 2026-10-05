function problem_configuration_snapshot(state::ProjectState, ctx::RuntimeContext)
    compiler = get(state.metadata, "compiler", nothing)
    compiler isa AbstractDict || return Dict{String,Any}[]
    records = get(compiler, "configuration_sources", Any[])
    records isa AbstractVector && length(records) <= 32 ||
        throw(ShenScopeError(:problems, "Compiler configuration identities are invalid"))
    result = Dict{String,Any}[]
    for record in records
        record isa AbstractDict && haskey(record, "path") && haskey(record, "sha256") ||
            throw(ShenScopeError(:problems, "Compiler configuration identity is invalid"))
        snapshot = read_workspace_snapshot(ctx, record["path"]; expected_sha256=record["sha256"],
            maximum_bytes=256*1024, tool="problems.configuration")
        push!(result, Dict("path" => snapshot.path, "sha256" => snapshot.sha256))
    end
    if isempty(records) && haskey(compiler, "configuration_entry")
        absolute, relative = workspace_snapshot_path(ctx, compiler["configuration_entry"]; must_exist=false)
        workspace_source_permission(ctx, absolute, "problems.configuration")
        !ispath(absolute) && !islink(absolute) ||
            throw(ShenScopeError(:stale_source, "Compiler configuration appeared since indexing"))
        push!(result, Dict("path" => relative, "sha256" => nothing))
    end
    project_verify_query_config(state, ctx)
    result
end

function capture_indexed_problems!(manager::ProblemManager, state::ProjectState, ctx::RuntimeContext;
        expected_revision=nothing, paths=nothing)
    state.root == ctx.root || throw(ShenScopeError(:permission, "Project index belongs to another workspace"))
    authorize!(ctx, :read, "problems", ctx.root; reason="Collect reported project diagnostics")
    limits = manager.limits
    lock(state.mutex) do
        workspace_source_checkpoint(ctx)
        expected_revision === nothing ||
            problem_integer(expected_revision, "expected index revision", 0, typemax(Int)-1) == state.revision ||
            throw(ShenScopeError(:conflict, "Project index revision changed"))
        configuration = problem_configuration_snapshot(state, ctx)
        selected = sort!(collect(keys(state.files)))
        if paths !== nothing
            paths isa AbstractVector && 1 <= length(paths) <= limits.maximum_files ||
                throw(ShenScopeError(:problems, "Invalid diagnostic file selection"))
            selected = sort!(unique([workspace_snapshot_path(ctx, problem_text(path, "diagnostic file", 4096))[2] for path in paths]))
            all(path -> haskey(state.files, path), selected) ||
                throw(ShenScopeError(:problems, "Diagnostic selection contains an unindexed file"))
        end
        files = ProblemFileReport[]
        omitted_files = 0
        read_bytes = 0
        item_count = 0
        reported_count = 0
        omitted_items = 0
        for path in selected
            workspace_source_checkpoint(ctx)
            facts = state.files[path]
            if length(files) >= limits.maximum_files || read_bytes >= limits.maximum_read_bytes
                omitted_files += 1
                continue
            end
            source = read_workspace_snapshot(ctx, path; expected_sha256=facts.sha256,
                maximum_bytes=limits.maximum_source_bytes, tool="problems.source")
            read_bytes + ncodeunits(source.source.source) <= limits.maximum_read_bytes || begin
                omitted_files += 1
                continue
            end
            read_bytes += ncodeunits(source.source.source)
            items = ProjectProblem[]
            reported_count += length(facts.diagnostics)
            available = min(limits.maximum_per_file, limits.maximum_items - item_count)
            for diagnostic in Iterators.take(facts.diagnostics, available)
                push!(items, normalize_indexed_problem(diagnostic, source; limits))
            end
            omitted = length(facts.diagnostics) - length(items)
            omitted_items += omitted
            item_count += length(items)
            status = !state.capabilities.diagnostics ? "no_diagnostic_capability" : omitted > 0 ? "limited" : "reported"
            push!(files, problem_file_report(source, items;
                reported_items=length(facts.diagnostics), omitted_items=omitted, status))
        end
        coverage = Dict("producer_kind" => "project_index", "backend" => state.backend,
            "supported_languages" => copy(state.capabilities.languages),
            "diagnostic_capability" => state.capabilities.diagnostics,
            "indexed_files" => length(state.files), "selected_files" => length(selected),
            "reported_files" => length(files), "omitted_files" => omitted_files,
            "reported_items" => reported_count, "omitted_items" => omitted_items,
            "source_bytes_read" => read_bytes, "truncated" => omitted_files > 0 || omitted_items > 0,
            "all_files_checked_by_compiler" => false)
        # Recheck configuration after all source reads. Snapshot publication is
        # evidence of observed bytes, never a lock against unrelated processes.
        problem_configuration_snapshot(state, ctx) == configuration ||
            throw(ShenScopeError(:stale_source, "Compiler configuration changed during diagnostic capture"))
        retain_problem_snapshot!(manager, ctx, state.backend, state.revision, files; configuration, coverage)
    end
end
