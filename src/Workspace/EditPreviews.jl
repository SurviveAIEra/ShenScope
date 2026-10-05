function workspace_contiguous_preview(file::WorkspaceFileEdit; context_lines=3, maximum_bytes=32*1024)
    context_lines isa Integer && !(context_lines isa Bool) && 0 <= context_lines <= 20 ||
        throw(ShenScopeError(:workspace_edit, "Invalid edit preview context"))
    before_lines = split(file.source.source.source, '\n'; keepempty=true)
    after_lines = split(file.after_text, '\n'; keepempty=true)
    prefix = 0
    while prefix < min(length(before_lines), length(after_lines)) && before_lines[prefix+1] == after_lines[prefix+1]
        prefix += 1
    end
    suffix = 0
    while suffix < min(length(before_lines)-prefix, length(after_lines)-prefix) &&
            before_lines[end-suffix] == after_lines[end-suffix]
        suffix += 1
    end
    unchanged = file.source.sha256 == file.after_sha256
    first = max(1, prefix-context_lines+1)
    before_last = min(length(before_lines), length(before_lines)-suffix+context_lines)
    after_last = min(length(after_lines), length(after_lines)-suffix+context_lines)
    output = IOBuffer(; maxsize=maximum_bytes)
    written = 0
    truncated = false
    function append_line(marker, line, text)
        cost = ncodeunits(text)+32
        if written + cost > maximum_bytes
            truncated = true
            return false
        end
        write(output, marker, string(line), " ", text, "\n")
        written += cost
        true
    end
    if !unchanged
        for index in first:prefix
            append_line(" ", index, before_lines[index]) || break
        end
        if !truncated
            for index in prefix+1:length(before_lines)-suffix
                append_line("-", index, before_lines[index]) || break
            end
        end
        if !truncated
            for index in prefix+1:length(after_lines)-suffix
                append_line("+", index, after_lines[index]) || break
            end
        end
        if !truncated
            for index in max(prefix+1, length(after_lines)-suffix+1):after_last
                append_line(" ", index, after_lines[index]) || break
            end
        end
    end
    Dict("path" => file.source.path, "before_sha256" => file.source.sha256,
        "after_sha256" => file.after_sha256, "changed" => !unchanged,
        "text" => String(take!(output)), "preview_truncated" => truncated,
        "preview_format" => "one_contiguous_changed_region_with_line_numbers",
        "before_lines" => length(before_lines), "after_lines" => length(after_lines))
end

function workspace_preview_file(file::WorkspaceFileEdit; context_lines=3, maximum_bytes=32*1024)
    options = WorkspaceDiffOptions(; context_lines, maximum_output_bytes=max(128, maximum_bytes))
    try
        diff = workspace_source_diff(file.source.path, file.source.source.source, file.after_text; options)
        workspace_diff_projection(diff; maximum_bytes=max(128, maximum_bytes))
    catch cause
        cause isa ShenScopeError && cause.code == :workspace_diff || rethrow()
        # A large replacement may exceed the bounded shortest-edit search.
        # Keep a usable bounded preview and identify its less precise grouping.
        preview = workspace_contiguous_preview(file; context_lines, maximum_bytes)
        preview["diff_search_capacity_exceeded"] = true
        preview
    end
end

function preview_workspace_edits(manager::WorkspaceEditManager, id::AbstractString, ctx::RuntimeContext;
        context_lines=3, include_text=false)
    include_text isa Bool || throw(ShenScopeError(:workspace_edit, "Invalid full preview option"))
    plan = owned_workspace_edit_plan(manager, id, ctx)
    authorize!(ctx, :read, "workspace.preview", ctx.root; reason="Inspect an owned workspace change proposal")
    files = Dict{String,Any}[]
    bytes = 0
    for file in plan.files
        manager.limits.maximum_preview_bytes - bytes >= 128 || break
        absolute, _ = workspace_snapshot_path(ctx, file.source.path; must_exist=false)
        workspace_source_permission(ctx, absolute, "workspace.preview")
        preview = workspace_preview_file(file; context_lines,
            maximum_bytes=min(32*1024, manager.limits.maximum_preview_bytes-bytes))
        bytes += ncodeunits(preview["text"])
        preview["source_current"] = try
            verify_workspace_snapshot(file.source, ctx; tool="workspace.preview")
            true
        catch cause
            cause isa ShenScopeError && cause.code in (:stale_source, :path, :conflict) || rethrow()
            false
        end
        if include_text
            bytes + ncodeunits(file.source.source.source) + ncodeunits(file.after_text) <= manager.limits.maximum_preview_bytes ||
                throw(ShenScopeError(:capacity, "Full edit preview exceeds capacity; request the bounded diff"))
            preview["before_text"] = file.source.source.source
            preview["after_text"] = file.after_text
            bytes += ncodeunits(file.source.source.source) + ncodeunits(file.after_text)
        end
        push!(files, preview)
        bytes < manager.limits.maximum_preview_bytes || break
    end
    Dict("plan_id" => plan.id, "plan_sha256" => plan.sha256, "files" => files,
        "omitted_files" => length(plan.files)-length(files), "requires_explicit_apply" => true,
        "source_current" => all(file -> file["source_current"], files))
end
