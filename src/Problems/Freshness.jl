function problem_file_freshness(file::ProblemFileReport, ctx::RuntimeContext; allow_ask=true)
    try
        source = read_workspace_snapshot(ctx, file.path; expected_sha256=file.sha256,
            tool="problems.source", allow_ask)
        return "current", source
    catch cause
        cause isa ShenScopeError || rethrow()
        cause.code == :stale_source && return "stale", nothing
        cause.code == :path && return "missing", nothing
        cause.code == :permission && return "permission_unavailable", nothing
        cause.code == :source && return "unreadable", nothing
        cause.code == :conflict && return "changed_during_read", nothing
        rethrow()
    end
end

function problem_configuration_current(snapshot::ProblemSnapshot, ctx::RuntimeContext; allow_ask=true)
    for record in snapshot.configuration
        try
            if record["sha256"] === nothing
                absolute, _ = workspace_snapshot_path(ctx, record["path"]; must_exist=false)
                workspace_source_permission(ctx, absolute, "problems.configuration"; allow_ask)
                !ispath(absolute) && !islink(absolute) || return false
            else
                read_workspace_snapshot(ctx, record["path"]; expected_sha256=record["sha256"],
                    maximum_bytes=256*1024, tool="problems.configuration", allow_ask)
            end
        catch cause
            cause isa ShenScopeError || rethrow()
            cause.code in (:stale_source, :path, :permission, :source, :conflict) || rethrow()
            return false
        end
    end
    true
end

function problem_current_files(snapshot::ProblemSnapshot, ctx::RuntimeContext; allow_ask=true)
    authorize!(ctx, :read, "problems", ctx.root; reason="Check current access and source versions for project diagnostics")
    snapshot.scope == problem_scope(ctx) || throw(ShenScopeError(:permission, "Foreign problem snapshot"))
    configuration_current = problem_configuration_current(snapshot, ctx; allow_ask)
    sources = Dict{String,WorkspaceSourceSnapshot}()
    statuses = Dict{String,String}()
    for file in snapshot.files
        workspace_source_checkpoint(ctx)
        status, source = problem_file_freshness(file, ctx; allow_ask)
        configuration_current || begin
            status == "permission_unavailable" || (status = "configuration_stale")
            source = nothing
        end
        statuses[file.path] = status
        source === nothing || (sources[file.path] = source)
    end
    sources, statuses, configuration_current
end

function problem_snapshot_read(manager::ProblemManager, id::AbstractString, ctx::RuntimeContext;
        allow_ask=true, include_stale=false)
    include_stale isa Bool || throw(ShenScopeError(:problems, "Invalid stale diagnostic option"))
    snapshot = owned_problem_snapshot(manager, id, ctx)
    sources, statuses, configuration_current = problem_current_files(snapshot, ctx; allow_ask)
    result = problem_snapshot_body(snapshot)
    result["snapshot_sha256"] = snapshot.sha256
    result["configuration_current"] = configuration_current
    result["current_source_validation"] = true
    result["historical_items_included"] = include_stale
    for file in result["files"]
        status = statuses[file["path"]]
        file["freshness"] = status
        if status != "current" && (!include_stale || status == "permission_unavailable")
            file["items_withheld"] = length(file["items"])
            file["items"] = Any[]
        end
        file["editor_publishable"] = status == "current"
    end
    # Withheld source data never acquires a new content hash. The hash above
    # refers to the retained producer snapshot, not this current projection.
    bounded_canonical_json(result; maximum=4*1024^2, max_depth=24, max_nodes=200_000)
    result
end

function read_problem_source(manager::ProblemManager, id::AbstractString, item_id::AbstractString,
        ctx::RuntimeContext; context_lines=3)
    snapshot = owned_problem_snapshot(manager, id, ctx)
    authorize!(ctx, :read, "problems", ctx.root; reason="Read source associated with a reported diagnostic")
    problem_hash(item_id, "problem item ID")
    selected = nothing
    for file in snapshot.files, item in file.items
        item.id == item_id && (selected = item; break)
    end
    selected === nothing && throw(ShenScopeError(:problems, "Problem item is absent from the owned snapshot"))
    selected.location === nothing && throw(ShenScopeError(:problems, "This diagnostic has no producer-reported source range"))
    source = read_workspace_snapshot(ctx, selected.path; expected_sha256=selected.source_sha256,
        tool="problems.source")
    workspace_source_excerpt(source, selected.location; context_lines)
end
