function workspace_history_checked_hash(value, description)
    value isa AbstractDict && haskey(value, "sha256") ||
        throw(ShenScopeError(:workspace_history, description * " has no content hash"))
    expected = workspace_edit_hash(value["sha256"], description * " hash")
    body = Dict{String,Any}(key => item for (key, item) in value if key != "sha256")
    digest(bounded_canonical_json(body; maximum=120*1024, max_depth=24, max_nodes=24_000)) == expected ||
        throw(ShenScopeError(:storage, description * " content hash does not match"))
    expected
end

function workspace_history_proposal_file(value, manifest, limits::WorkspaceEditLimits)
    workspace_edit_fields(value, ["path", "expected_sha256", "line_break_policy", "edits"],
        String[], "saved workspace file proposal")
    path = workspace_edit_text(value["path"], "saved workspace proposal path", 4096)
    path == manifest["path"] && workspace_edit_hash(value["expected_sha256"], "saved source hash") == manifest["before_sha256"] ||
        throw(ShenScopeError(:storage, "Saved proposal file differs from its manifest"))
    value["line_break_policy"] in ("unicode_source", "lsp_cr_lf") &&
        value["line_break_policy"] == manifest["line_break_policy"] ||
        throw(ShenScopeError(:storage, "Saved proposal line-break policy differs from its manifest"))
    edits = value["edits"]
    edits isa AbstractVector && 1 <= length(edits) <= limits.maximum_edits &&
        manifest["edits"] isa AbstractVector && length(edits) == length(manifest["edits"]) ||
        throw(ShenScopeError(:workspace_history, "Saved workspace edit array is invalid"))
    for (edit, stamp) in zip(edits, manifest["edits"])
        workspace_edit_fields(edit, ["location", "new_text"], String[], "saved source edit")
        edit["location"] == stamp["location"] ||
            throw(ShenScopeError(:storage, "Saved source edit range differs from its manifest"))
        location = edit["location"]
        workspace_edit_fields(location, ["file", "start_line", "end_line"],
            ["start_column", "end_column", "column_unit"], "saved source range")
        location["file"] == path && get(location, "column_unit", "utf8_byte") == "utf8_byte" ||
            throw(ShenScopeError(:workspace_history, "Saved source range has another file or encoding"))
        first_line = language_integer(location["start_line"], "saved edit start line", 1, 2^31-1)
        last_line = language_integer(location["end_line"], "saved edit end line", first_line, 2^31-1)
        first_column = language_integer(get(location, "start_column", 1), "saved edit start column", 1, 8*1024^2)
        last_column = language_integer(get(location, "end_column", 1), "saved edit end column", 1, 8*1024^2)
        first_line < last_line || first_column <= last_column ||
            throw(ShenScopeError(:workspace_history, "Saved source range is reversed"))
        text = workspace_edit_text(edit["new_text"], "saved replacement", limits.maximum_file_bytes; empty=true)
        digest(text) == stamp["new_text_sha256"] && ncodeunits(text) == stamp["new_text_bytes"] ||
            throw(ShenScopeError(:storage, "Saved replacement content differs from its manifest"))
    end
    path
end

function workspace_history_manifest(value, ctx::RuntimeContext)
    workspace_edit_fields(value, ["schema", "plan_id", "root_sha256", "session_id", "title", "origin", "created_at",
        "files", "requires_explicit_apply", "multi_file_power_loss_atomic"], String[], "saved workspace manifest")
    value["schema"] == WORKSPACE_EDIT_SCHEMA && value["root_sha256"] == digest(ctx.root) &&
        value["session_id"] == ctx.session_id && value["requires_explicit_apply"] === true &&
        value["multi_file_power_loss_atomic"] === false ||
        throw(ShenScopeError(:permission, "Saved workspace manifest has another owner or unsupported guarantees"))
    workspace_history_id(value["plan_id"])
    workspace_edit_text(value["title"], "saved edit title", 1024)
    workspace_edit_text(value["origin"], "saved edit origin", 256)
    workspace_edit_text(value["created_at"], "saved edit creation time", 64)
    files = value["files"]
    files isa AbstractVector && 1 <= length(files) <= 128 ||
        throw(ShenScopeError(:workspace_history, "Saved workspace manifest requires bounded files"))
    for file in files
        workspace_edit_fields(file, ["path", "before_sha256", "after_sha256", "before_bytes", "after_bytes", "edits",
            "line_break_policy"], String[], "saved file manifest")
        workspace_edit_hash(file["before_sha256"], "saved before hash")
        workspace_edit_hash(file["after_sha256"], "saved after hash")
        language_integer(file["before_bytes"], "saved before bytes", 0, 8*1024^2)
        language_integer(file["after_bytes"], "saved after bytes", 0, 8*1024^2)
        file["edits"] isa AbstractVector || throw(ShenScopeError(:workspace_history, "Saved edit manifest is invalid"))
        for edit in file["edits"]
            workspace_edit_fields(edit, ["location", "new_text_sha256", "new_text_bytes"], String[], "saved edit stamp")
            workspace_edit_hash(edit["new_text_sha256"], "saved replacement hash")
            language_integer(edit["new_text_bytes"], "saved replacement bytes", 0, 8*1024^2)
        end
    end
    value
end

function workspace_history_record(value, ctx::RuntimeContext, limits::WorkspaceHistoryLimits)
    workspace_history_json(value, limits)
    workspace_edit_fields(value, ["schema", "root_sha256", "session_id", "manifest", "plan_sha256", "status",
        "proposals", "receipt", "verification", "saved_at", "sha256"], String[], "saved workspace history")
    value["schema"] == WORKSPACE_HISTORY_SCHEMA && value["root_sha256"] == digest(ctx.root) &&
        value["session_id"] == ctx.session_id ||
        throw(ShenScopeError(:permission, "Saved workspace history belongs to another owner"))
    workspace_history_checked_hash(value, "Saved workspace history")
    manifest = workspace_history_manifest(value["manifest"], ctx)
    digest(bounded_canonical_json(manifest; maximum=2*1024^2, max_depth=16, max_nodes=32_000)) ==
        workspace_edit_hash(value["plan_sha256"], "saved plan hash") ||
        throw(ShenScopeError(:storage, "Saved workspace manifest hash does not match"))
    value["status"] in ("prepared", "discarded", "applied", "not_applied", "rolled_back", "partial") ||
        throw(ShenScopeError(:workspace_history, "Busy or unknown workspace state cannot be saved"))
    proposals = value["proposals"]
    proposals isa AbstractVector && length(proposals) == length(manifest["files"]) ||
        throw(ShenScopeError(:workspace_history, "Saved workspace proposals do not match their file manifest"))
    edit_limits = WorkspaceEditLimits(; maximum_files=128)
    paths = [workspace_history_proposal_file(proposal, stamp, edit_limits)
        for (proposal, stamp) in zip(proposals, manifest["files"])]
    length(unique(paths)) == length(paths) || throw(ShenScopeError(:workspace_history, "Saved workspace proposal repeats a path"))
    receipt = value["receipt"]
    if receipt !== nothing
        workspace_history_checked_hash(receipt, "Saved application receipt")
        receipt["schema"] == "shenscope.workspace-edit-receipt/1" &&
            receipt["plan_id"] == manifest["plan_id"] && receipt["plan_sha256"] == value["plan_sha256"] &&
            receipt["root_sha256"] == digest(ctx.root) && receipt["session_id"] == ctx.session_id &&
            receipt["outcome"] == value["status"] ||
            throw(ShenScopeError(:storage, "Saved application receipt has a different proposal or outcome"))
    elseif value["status"] in ("applied", "not_applied", "rolled_back", "partial")
        throw(ShenScopeError(:storage, "Saved executed proposal has no application receipt"))
    end
    verification = value["verification"]
    if verification !== nothing
        workspace_history_checked_hash(verification, "Saved command verification")
        receipt !== nothing && value["status"] == "applied" &&
            verification["schema"] == "shenscope.workspace-verification/1" &&
            verification["plan_id"] == manifest["plan_id"] && verification["plan_sha256"] == value["plan_sha256"] ||
            throw(ShenScopeError(:storage, "Saved command verification refers to a different proposal"))
        get(verification, "application_receipt_sha256", receipt["sha256"]) == receipt["sha256"] ||
            throw(ShenScopeError(:storage, "Saved command verification refers to another application receipt"))
    end
    workspace_edit_text(value["saved_at"], "workspace history save time", 64)
    deepcopy(value)
end
