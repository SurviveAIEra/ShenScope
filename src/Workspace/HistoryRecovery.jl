function workspace_history_source_state(file::AbstractDict, ctx::RuntimeContext)
    path = workspace_edit_text(file["path"], "saved workspace file", 4096)
    absolute, relative = workspace_snapshot_path(ctx, path; must_exist=false)
    workspace_source_permission(ctx, absolute, "workspace.history")
    state = "unavailable"
    sha256 = nothing
    if isfile(absolute)
        try
            snapshot = read_workspace_snapshot(ctx, relative; tool="workspace.history", maximum_bytes=8*1024^2,
                unicode_line_separators=file["line_break_policy"] == "unicode_source")
            sha256 = snapshot.sha256
            state = sha256 == file["before_sha256"] ? "matches_before" :
                sha256 == file["after_sha256"] ? "matches_after" : "changed"
            file["before_sha256"] == file["after_sha256"] && sha256 == file["before_sha256"] &&
                (state = "matches_both")
        catch cause
            cause isa ShenScopeError && cause.code in (:stale_source, :path, :conflict, :capacity, :input) || rethrow()
        end
    elseif !ispath(absolute)
        state = "missing"
    end
    Dict("path" => relative, "source_state" => state, "current_sha256" => sha256,
        "before_sha256" => file["before_sha256"], "after_sha256" => file["after_sha256"])
end

function inspect_workspace_history_sources(store::WorkspaceHistoryStore, id::AbstractString,
        ctx::RuntimeContext; expected_version)
    record, payload = workspace_history_read_record(store, id, ctx; expected_version)
    files = Dict{String,Any}[]
    for file in payload["manifest"]["files"]
        workspace_source_checkpoint(ctx)
        push!(files, workspace_history_source_state(file, ctx))
    end
    all_before = all(row -> row["source_state"] in ("matches_before", "matches_both"), files)
    all_after = all(row -> row["source_state"] in ("matches_after", "matches_both"), files)
    Dict("history_id" => record["key"], "version" => record["version"],
        "files" => files, "all_files_match_before" => all_before, "all_files_match_after" => all_after,
        "saved_status" => payload["status"], "automatic_replay" => false,
        "source_identity_proves_command_success" => false,
        "commands_rerun" => false, "all_project_inputs_verified" => false)
end

function restore_workspace_proposal!(store::WorkspaceHistoryStore, manager::WorkspaceEditManager,
        id::AbstractString, ctx::RuntimeContext; expected_version, expected_record_sha256)
    record, payload = workspace_history_read_record(store, id, ctx; expected_version)
    workspace_edit_hash(expected_record_sha256, "reviewed history record hash") == payload["sha256"] ||
        throw(ShenScopeError(:conflict, "Saved workspace proposal differs from the reviewed record"))
    payload["status"] == "prepared" ||
        throw(ShenScopeError(:workspace_history, "Only an explicitly saved pending proposal can be restored"))
    # Restore by revalidating all current files, ranges and replacement content.
    # This creates a new proposal identity and hash, requiring a new explicit
    # apply request. No source backups or command receipts are replayed.
    manifest = payload["manifest"]
    plan = prepare_workspace_edits!(manager, ctx, payload["proposals"];
        title=manifest["title"], origin=manifest["origin"])
    Dict("proposal" => plan, "restored_from_history_id" => record["key"],
        "restored_from_version" => record["version"], "requires_new_apply" => true,
        "workspace_files_modified" => false, "commands_started" => false,
        "historical_receipts_replayed" => false)
end
