function git_history_snapshot(ctx::RuntimeContext;limits=GitHistoryLimits())
    repository = git_history_repository(ctx)
    deadline_ns = time_ns() + UInt64(ceil(limits.timeout_seconds * 1e9))
    manager = ProcessManager(;max_handles=1)
    try
        version = git_history_version(git_history_scalar(git_history_command(repository, :version, manager, ctx, deadline_ns, limits)))
        head = git_history_scalar(git_history_command(repository, :head, manager, ctx, deadline_ns, limits))
        git_object_id(head) || throw(ShenScopeError(:git_protocol, "Git HEAD is not a full commit identity"))
        shallow_text = git_history_scalar(git_history_command(repository, :shallow, manager, ctx, deadline_ns, limits))
        shallow_text in ("true", "false") || throw(ShenScopeError(:git_protocol, "Invalid Git shallow-history response"))
        emit!(ctx, :git_history_started, Dict("head" => head, "commit_limit" => limits.commits,
            "history_mode" => "first_parent", "shallow" => shallow_text == "true"))
        bytes = git_history_command(repository, :history, manager, ctx, deadline_ns, limits;head)
        commits, limit_reached = parse_git_history(bytes, head, limits)
        final_head = git_history_scalar(git_history_command(repository, :verify_head, manager, ctx, deadline_ns, limits))
        final_head == head || throw(ShenScopeError(:conflict, "Git HEAD changed during history analysis; request a fresh snapshot"))
        snapshot = GitHistorySnapshot(repository.root, head, ncodeunits(head) == 40 ? "sha1" : "sha256", version,
            shallow_text == "true", commits, limit_reached, bytes2hex(sha256(bytes)), length(bytes), limits)
        emit!(ctx, :git_history_completed, git_history_coverage(snapshot))
        snapshot
    finally
        cleanup_processes!(manager, ctx.session_id)
    end
end

function git_history_coverage(snapshot::GitHistorySnapshot)
    skipped = count(commit -> length(commit.changes) + commit.omitted_changes > snapshot.limits.bulk_threshold ||
        commit.omitted_changes > 0, snapshot.commits)
    protected = sum(count(change -> !git_history_public_path(change.path), commit.changes) for commit in snapshot.commits;init=0)
    Dict("head" => snapshot.head, "object_format" => snapshot.object_format, "git_version" => snapshot.git_version,
        "history_mode" => "first_parent", "merge_diff_mode" => "first_parent", "rename_mode" => "delete_and_add",
        "commits_scanned" => length(snapshot.commits), "commit_limit" => snapshot.limits.commits,
        "limit_reached" => snapshot.limit_reached, "shallow" => snapshot.shallow,
        "bulk_commits_excluded" => skipped, "bulk_threshold" => snapshot.limits.bulk_threshold,
        "protected_changes_excluded" => protected, "output_bytes" => snapshot.output_bytes,
        "raw_sha256" => snapshot.raw_sha256, "working_tree_included" => false,
        "availability_proof" => false, "scope" => "local_workspace_repository")
end

function git_history_commit_evidence(commit::GitHistoryCommit)
    Dict("commit" => commit.id, "parents" => collect(commit.parents), "committed_at" => commit.committed_at,
        "ordinal" => commit.ordinal, "changed_files" => length(commit.changes) + commit.omitted_changes,
        "provenance" => "git_local_first_parent_numstat")
end
