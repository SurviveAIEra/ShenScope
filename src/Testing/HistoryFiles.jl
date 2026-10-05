function project_test_history_scope(store::ProjectTestHistoryStore,ctx::RuntimeContext)
    expected=project_test_history_store(ctx;limits=store.limits)
    store.directory==expected.directory && store.workspace_sha256==expected.workspace_sha256 && store.session_id==expected.session_id ||
        throw(ShenScopeError(:permission,"Saved test history belongs to another conversation or workspace"))
    nothing
end
function project_test_history_guard(store::ProjectTestHistoryStore,ctx::RuntimeContext)
    project_test_history_scope(store,ctx)
    for suffix in ("",".lock");memory_path_guard(project_test_history_path(store)*suffix,ctx);end
    nothing
end
function project_test_history_checkpoint(store::ProjectTestHistoryStore,ctx::RuntimeContext,category::Symbol)
    project_test_history_scope(store,ctx);project_test_checkpoint(ctx;read_target=ctx.root)
    target=project_test_history_target(store)
    for required in unique([:read,category])
        permission_decision(ctx.permissions,PermissionRequest("testing-history-current",required,"testing.history",target,
            "Current saved test history permission"))!=Deny || throw(ShenScopeError(:permission,"Saved test history permission was revoked"))
    end
    yield();nothing
end
function project_test_history_authorize(store::ProjectTestHistoryStore,ctx::RuntimeContext,category::Symbol)
    project_test_history_scope(store,ctx)
    authorize!(ctx,:read,"testing",ctx.root;reason="Read captured project test evidence")
    authorize!(ctx,:read,"testing.history",project_test_history_target(store);reason="Read this conversation's saved test records")
    category==:read || authorize!(ctx,category,"testing.history",project_test_history_target(store);
        reason="Save or change bounded test records without executing any test command")
    project_test_history_checkpoint(store,ctx,category);project_test_history_guard(store,ctx)
end
function project_test_history_read(store::ProjectTestHistoryStore,ctx::RuntimeContext;category=:read)
    project_test_history_checkpoint(store,ctx,category);project_test_history_guard(store,ctx)
    path=project_test_history_path(store);before=journal_file_identity(path)
    before===nothing && return project_test_history_empty(store)
    before.bytes<=store.limits.snapshot_bytes || throw(ShenScopeError(:capacity,"Saved test history exceeds its byte limit"))
    raw=try
        open(path,"r") do input
            bytes=read(input,store.limits.snapshot_bytes+1)
            length(bytes)<=store.limits.snapshot_bytes && isvalid(String(copy(bytes))) ||
                throw(ShenScopeError(:testing,"Saved test history exceeds capacity or contains invalid UTF-8"))
            String(bytes)
        end
    catch cause
        cause isa ShenScopeError && rethrow()
        throw(ShenScopeError(:conflict,"Unable to read saved test history"))
    end
    project_test_history_checkpoint(store,ctx,category);project_test_history_guard(store,ctx)
    journal_file_identity(path)==before || throw(ShenScopeError(:conflict,"Saved test history changed while reading"))
    value=bounded_json_object(raw;maximum=store.limits.snapshot_bytes,max_depth=24,max_nodes=1_000_000,error_code=:testing)
    project_test_history_validate(value,store,ctx)
end

function project_test_history_stage_admission(store::ProjectTestHistoryStore,ctx::RuntimeContext)
    path=project_test_history_path(store);project_test_history_guard(store,ctx)
    checkpoint=()->project_test_history_checkpoint(store,ctx,:persistence)
    # Only independently identified, dead-process Core staging files can be
    # reclaimed. Current snapshots, user files and live stages are untouched.
    reclaim_atomic_staging!(path;minimum_age_seconds=3600.0,checkpoint)
    directory=atomic_staging_directory(path);directory===nothing && return
    names=readdir(directory);length(names)<=64 || throw(ShenScopeError(:capacity,"Saved test staging entry limit reached"))
    total=0
    for name in names
        checkpoint();file=joinpath(directory,name)
        isfile(file) && !islink(file) && realpath(file)==file || throw(ShenScopeError(:permission,"Saved test staging contains an unsafe entry"))
        bytes=filesize(file);bytes<=store.limits.snapshot_bytes || throw(ShenScopeError(:capacity,"Saved test staging file exceeds capacity"))
        total+=bytes
    end
    total<=2*store.limits.snapshot_bytes || throw(ShenScopeError(:capacity,"Saved test staging byte limit reached"))
    nothing
end
