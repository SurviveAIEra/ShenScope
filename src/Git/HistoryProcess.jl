function git_history_argv(repository::GitHistoryRepository, phase::Symbol;head=nothing, limits=GitHistoryLimits())
    phase in GIT_HISTORY_PHASES || throw(ShenScopeError(:arguments, "Unknown Git history phase"))
    base = String[repository.executable, "--no-pager", "--no-optional-locks",
        "--git-dir=" * repository.git_directory, "--work-tree=" * repository.root,
        "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "color.ui=false",
        "-c", "diff.external=", "-c", "core.pager=cat",
        "-c", "core.attributesFile=" * (Sys.iswindows() ? "NUL" : "/dev/null"),
        "-c", "core.hooksPath=" * (Sys.iswindows() ? "NUL" : "/dev/null")]
    phase == :version && return vcat(base, ["--version"])
    phase in (:head, :verify_head) && return vcat(base, ["rev-parse", "--verify", "HEAD^{commit}"])
    phase == :shallow && return vcat(base, ["rev-parse", "--is-shallow-repository"])
    head isa String && git_object_id(head) || throw(ShenScopeError(:arguments, "A fixed commit is required for history"))
    vcat(base, ["log", "--max-count=" * string(limits.commits + 1), "--first-parent",
        "--diff-merges=first-parent", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-show-signature",
        "--no-notes", "--format=%x00%H%x00%P%x00%ct%x00", "--numstat", "-z", head, "--"])
end

function git_history_command(repository::GitHistoryRepository, phase::Symbol, manager::ProcessManager,
        ctx::RuntimeContext, deadline_ns::UInt64, limits::GitHistoryLimits;head=nothing)
    verify_git_repository(repository, ctx)
    remaining = (deadline_ns - min(time_ns(), deadline_ns)) / 1e9
    remaining >= 0.01 || throw(ShenScopeError(:timeout, "Git history operation timed out"))
    argv = git_history_argv(repository, phase;head, limits)
    output_limit = phase == :history ? limits.output_bytes : 4096
    handle = start_process!(manager, argv, ctx;cwd=repository.root, timeout=remaining, output_limit,
        environment=git_history_environment(), emit_output=false, permission_tool="git.history",
        before_start=()->begin
            verify_git_repository(repository, ctx)
            time_ns() < deadline_ns || throw(ShenScopeError(:timeout, "Git history approval exhausted the deadline"))
        end)
    try
        close(handle.input)
        while !istaskdone(handle.monitor)
            check_cancelled(ctx.cancellation)
            lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
            verify_read = permission_decision(ctx.permissions, PermissionRequest("git-history-running", :read,
                "git.history", repository.root, "Recheck history read"))
            verify_process = permission_decision(ctx.permissions, PermissionRequest("git-history-running", :process,
                "git.history", canonical(Dict("argv" => argv, "cwd" => repository.root)), "Recheck history process"))
            (verify_read == Deny || verify_process == Deny) && throw(ShenScopeError(:permission, "Git history permission was revoked"))
            time_ns() < deadline_ns || throw(ShenScopeError(:timeout, "Git history operation timed out"))
            total = lock(handle.stdout.mutex) do; handle.stdout.total; end
            total <= output_limit || throw(ShenScopeError(:capacity, "Git history output exceeded capacity"))
            sleep(0.01)
        end
        wait(handle.monitor)
        check_cancelled(ctx.cancellation)
        lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
        handle.timed_out && throw(ShenScopeError(:timeout, "Git history child timed out"))
        handle.process.exitcode == 0 || throw(ShenScopeError(:git_process, "Local Git history phase failed: " * String(phase)))
        total, bytes = lock(handle.stdout.mutex) do; (handle.stdout.total, vcat(handle.stdout.head, handle.stdout.tail)); end
        total == length(bytes) && total <= output_limit || throw(ShenScopeError(:capacity, "Git history output was truncated"))
        verify_git_repository(repository, ctx)
        bytes
    finally
        terminate_process!(handle)
        try wait(handle.monitor) catch end
        lock(manager.mutex) do; delete!(manager.handles, handle.id); end
    end
end

function git_history_scalar(bytes::Vector{UInt8})
    value = String(copy(bytes))
    isvalid(value) && endswith(value, '\n') && !occursin('\0', value) ||
        throw(ShenScopeError(:git_protocol, "Invalid Git scalar response"))
    text = chomp(value)
    occursin('\n', text) && throw(ShenScopeError(:git_protocol, "Unexpected multiline Git response"))
    String(text)
end

function git_history_version(value::String)
    parsed = match(r"^git version ([0-9]+)\.([0-9]+)(?:\.[0-9]+)?(?:[. -][A-Za-z0-9._ -]+)?$", value)
    parsed === nothing && throw(ShenScopeError(:git_protocol, "Unrecognized Git version response"))
    major = tryparse(Int, parsed.captures[1]); minor = tryparse(Int, parsed.captures[2])
    major !== nothing && minor !== nothing && (major > 2 || major == 2 && minor >= 43) ||
        throw(ShenScopeError(:git_unavailable, "Git history requires Git 2.43 or later for no-lazy-fetch support"))
    value
end
