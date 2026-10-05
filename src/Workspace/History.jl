function workspace_history_payload(plan::WorkspaceEditPlan, limits::WorkspaceHistoryLimits)
    lock(plan.mutex) do
        plan.status in (:applying, :verifying) &&
            throw(ShenScopeError(:workspace_busy, "Finish applying or verifying the proposal before saving it"))
        payload = Dict{String,Any}("schema" => WORKSPACE_HISTORY_SCHEMA,
            "root_sha256" => digest(plan.scope[1]), "session_id" => plan.scope[3],
            "manifest" => workspace_plan_manifest(plan), "plan_sha256" => plan.sha256,
            "status" => String(plan.status), "receipt" => deepcopy(plan.receipt),
            "verification" => deepcopy(plan.verification), "saved_at" => utcstamp(),
            "proposals" => [Dict("path" => file.source.path, "expected_sha256" => file.source.sha256,
                "line_break_policy" => file.source.source.unicode_line_separators ? "unicode_source" : "lsp_cr_lf",
                "edits" => [Dict("location" => range_dict(edit.location), "new_text" => edit.new_text)
                    for edit in file.edits]) for file in plan.files])
        payload["sha256"] = digest(workspace_history_json(payload, limits))
        workspace_history_json(payload, limits)
        payload
    end
end

function save_workspace_history!(store::WorkspaceHistoryStore, manager::WorkspaceEditManager,
        id::AbstractString, ctx::RuntimeContext; expected_plan_sha256, expected_version)
    version = workspace_history_version(expected_version; zero=true)
    workspace_history_access(store, ctx; write=true)
    plan = owned_workspace_edit_plan(manager, id, ctx)
    workspace_plan_expected_hash(plan, expected_plan_sha256)
    payload = workspace_history_payload(plan, store.limits)
    workspace_history_record(payload, ctx, store.limits)
    workspace_source_checkpoint(ctx)
    record = version_put!(store.store, plan.id, payload; expected_version=version)
    Dict("history_id" => plan.id, "version" => record["version"],
        "record_sha256" => payload["sha256"], "plan_sha256" => plan.sha256,
        "saved_status" => payload["status"], "source_backups_saved" => false,
        "automatic_execution" => false, "survives_restart" => true)
end

function workspace_history_read_record(store::WorkspaceHistoryStore, id::AbstractString,
        ctx::RuntimeContext; expected_version=nothing)
    workspace_history_access(store, ctx)
    identifier = workspace_history_id(id)
    record = version_get(store.store, identifier)
    record === nothing && throw(ShenScopeError(:workspace_history, "Saved workspace change is absent or deleted"))
    expected_version === nothing || workspace_history_version(expected_version) == record["version"] ||
        throw(ShenScopeError(:conflict, "Saved workspace history revision changed"))
    payload = workspace_history_record(record["value"], ctx, store.limits)
    payload["manifest"]["plan_id"] == identifier ||
        throw(ShenScopeError(:storage, "Saved workspace history key differs from its proposal ID"))
    record, payload
end

function read_workspace_history(store::WorkspaceHistoryStore, id::AbstractString,
        ctx::RuntimeContext; expected_version=nothing)
    record, payload = workspace_history_read_record(store, id, ctx; expected_version)
    Dict("history_id" => record["key"], "version" => record["version"], "record" => payload,
        "evidence_is_historical" => true, "requires_current_source_checks" => true,
        "automatic_replay" => false, "source_backups_saved" => false)
end

function list_workspace_history(store::WorkspaceHistoryStore, ctx::RuntimeContext)
    workspace_history_access(store, ctx)
    result = Dict{String,Any}[]
    for record in version_list(store.store)
        payload = workspace_history_record(record["value"], ctx, store.limits)
        manifest = payload["manifest"]
        manifest["plan_id"] == record["key"] || throw(ShenScopeError(:storage, "Saved workspace history key mismatch"))
        push!(result, Dict("history_id" => record["key"], "version" => record["version"],
            "title" => manifest["title"], "status" => payload["status"],
            "files" => length(manifest["files"]), "plan_sha256" => payload["plan_sha256"],
            "record_sha256" => payload["sha256"], "saved_at" => payload["saved_at"]))
    end
    sort!(result; by=row -> (row["saved_at"], row["history_id"]), rev=true)
    Dict("history" => result, "survives_restart" => true, "automatic_replay" => false,
        "maximum_entries_including_tombstones" => store.limits.maximum_entries,
        "source_backups_saved" => false)
end

function remove_workspace_history!(store::WorkspaceHistoryStore, id::AbstractString,
        ctx::RuntimeContext; expected_version)
    workspace_history_access(store, ctx; write=true)
    record, payload = workspace_history_read_record(store, id, ctx; expected_version)
    workspace_source_checkpoint(ctx)
    deleted = version_put!(store.store, record["key"], nothing;
        expected_version=record["version"], deleted=true)
    Dict("history_id" => record["key"], "version" => deleted["version"],
        "deleted" => true, "workspace_files_modified" => false,
        "deletion_semantics" => "versioned_tombstone_not_secure_erasure")
end
