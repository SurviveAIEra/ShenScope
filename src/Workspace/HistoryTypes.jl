const WORKSPACE_HISTORY_SCHEMA = "shenscope.workspace-edit-history/1"

Base.@kwdef struct WorkspaceHistoryLimits
    maximum_entries::Int = 64
    maximum_record_bytes::Int = 120*1024
    maximum_log_bytes::Int = 8*1024^2
    retained_versions::Int = 2
end

function validate_workspace_history_limits(limits::WorkspaceHistoryLimits)
    1 <= limits.maximum_entries <= 256 &&
        1024 <= limits.maximum_record_bytes <= 120*1024 &&
        limits.maximum_record_bytes <= limits.maximum_log_bytes <= 32*1024^2 &&
        1 <= limits.retained_versions <= 8 ||
        throw(ShenScopeError(:workspace_history, "Invalid workspace history capacities"))
    limits
end

struct WorkspaceHistoryStore
    scope::Tuple{String,String,String}
    store::VersionedStore
    limits::WorkspaceHistoryLimits
end

function workspace_history_store(ctx::RuntimeContext; limits=WorkspaceHistoryLimits())
    validate_workspace_history_limits(limits)
    path = joinpath(ctx.state_dir, "workspace-changes", digest(ctx.root), digest(ctx.session_id)*".jsonl")
    journal = VersionedStore(path; max_entries=limits.maximum_entries,
        max_log_bytes=limits.maximum_log_bytes, history_limit=limits.retained_versions)
    WorkspaceHistoryStore(operation_scope(ctx), journal, limits)
end

function workspace_history_access(store::WorkspaceHistoryStore, ctx::RuntimeContext; write=false)
    store.scope == operation_scope(ctx) ||
        throw(ShenScopeError(:permission, "Workspace history belongs to another conversation or workspace"))
    target = "workspace-history:" * digest(ctx.root) * ":" * ctx.session_id
    authorize!(ctx, :read, "workspace.history", target; reason="Read explicitly saved workspace change history")
    write && authorize!(ctx, :persistence, "workspace.history", target;
        reason="Save this conversation's bounded change proposals and receipts")
    path = store.store.journal.path
    cursor = path
    while cursor != dirname(cursor) && cursor != ctx.state_dir
        islink(cursor) && throw(ShenScopeError(:storage, "Workspace history path may not traverse a symlink"))
        cursor = dirname(cursor)
    end
    isfile(path) && filesize(path) > store.limits.maximum_log_bytes &&
        throw(ShenScopeError(:capacity, "Workspace change history exceeds its read capacity"))
    workspace_source_checkpoint(ctx)
    nothing
end

function workspace_history_version(value; zero=false)
    language_integer(value, "workspace history version", zero ? 0 : 1, typemax(Int)-1)
end

function workspace_history_id(value)
    identifier = workspace_edit_text(value, "saved workspace change ID", 128)
    valid_id(identifier)
    identifier
end

function workspace_history_json(value, limits::WorkspaceHistoryLimits)
    bounded_canonical_json(value; maximum=limits.maximum_record_bytes,
        max_depth=24, max_nodes=24_000)
end
