function session_control_scope(session::Session,ctx::RuntimeContext)
    session.id==ctx.session_id && realpath(session.root)==ctx.root ||
        throw(ShenScopeError(:permission,"Conversation control belongs to another runtime"))
    expected=joinpath(ctx.state_dir,"sessions",valid_id(session.id)*".jsonl")
    abspath(session.journal.path)==expected && workspace_path(ctx.state_dir,expected)==expected ||
        throw(ShenScopeError(:permission,"Conversation control journal escapes its state directory"))
    expected
end

function with_session_run_fence(f::Function,session::Session,ctx::RuntimeContext)
    path=session_control_scope(session,ctx)*".run"
    islink(path*".lock") && throw(ShenScopeError(:permission,"Conversation run fence cannot be a symlink"))
    check=()->begin
        check_cancelled(ctx.cancellation);check_budget(ctx.budget)
        session_control_scope(session,ctx)
        islink(path*".lock") && throw(ShenScopeError(:permission,"Conversation run fence changed to a symlink"))
    end
    store_lock(path;checkpoint=check,nonblocking=true) do
        observed=walk_journal((record,sequence,bytes)->nothing,session.journal;checkpoint=check)
        observed.records==session.revision ||
            throw(ShenScopeError(:conflict,"Conversation changed before acquiring its execution fence"))
        f()
    end
end
