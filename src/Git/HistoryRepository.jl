function git_metadata_file(path::String;maximum=128 * 1024, required=false)
    islink(path) && throw(ShenScopeError(:git_repository, "Git metadata symlinks are unsupported"))
    if !ispath(path)
        required && throw(ShenScopeError(:git_repository, "Required Git metadata is missing"))
        return UInt8[]
    end
    isfile(path) || throw(ShenScopeError(:git_repository, "Expected an ordinary Git metadata file"))
    data = open(path, "r") do io; read(io, maximum + 1); end
    length(data) <= maximum || throw(ShenScopeError(:capacity, "Git metadata exceeds read capacity"))
    data
end

function git_repository_declaration(root::String)
    directory = joinpath(root, ".git")
    isdir(directory) && !islink(directory) && realpath(directory) == directory ||
        throw(ShenScopeError(:git_repository, "History requires a workspace-root repository with an ordinary .git directory"))
    for name in ("objects", "objects/info", "objects/pack", "refs", "refs/heads", "info")
        path = joinpath(directory, split(name, '/')...)
        islink(path) && throw(ShenScopeError(:git_repository, "Git metadata directory symlinks are unsupported"))
        ispath(path) && !isdir(path) && throw(ShenScopeError(:git_repository, "Invalid Git metadata directory"))
    end
    for name in ("commondir", "gitdir", "objects/info/alternates", "objects/info/http-alternates", "info/grafts")
        path = joinpath(directory, split(name, '/')...)
        (ispath(path) || islink(path)) && throw(ShenScopeError(:git_repository, "External Git storage and history redirects are unsupported"))
    end
    config = git_metadata_file(joinpath(directory, "config");required=true)
    text = String(copy(config))
    isvalid(text) || throw(ShenScopeError(:git_repository, "Git configuration must be valid UTF-8"))
    # Reject includes instead of following configuration into another directory.
    # Worktree-specific configuration is unsupported by this root-only reader.
    occursin(r"(?im)^\s*\[\s*include(?:if)?(?:\s|\])", text) &&
        throw(ShenScopeError(:git_repository, "Included Git configuration is unsupported for history analysis"))
    (ispath(joinpath(directory, "config.worktree")) || islink(joinpath(directory, "config.worktree"))) &&
        throw(ShenScopeError(:git_repository, "Worktree-specific Git configuration is unsupported"))
    shallow = git_metadata_file(joinpath(directory, "shallow"))
    Dict("root" => root, "git_directory" => directory, "config_sha256" => bytes2hex(sha256(config)),
        "shallow_sha256" => bytes2hex(sha256(shallow)))
end

function git_history_repository(ctx::RuntimeContext)
    authorize!(ctx, :read, "git.history", ctx.root;reason="Read bounded local Git commit and file-change evidence")
    root = realpath(ctx.root)
    declaration = git_repository_declaration(root)
    executable = Sys.which("git")
    executable === nothing && throw(ShenScopeError(:git_unavailable, "Git executable is unavailable"))
    GitHistoryRepository(root, declaration["git_directory"], realpath(executable), digest(canonical(declaration)))
end

function verify_git_repository(repository::GitHistoryRepository, ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    repository.root == ctx.root && realpath(ctx.root) == repository.root ||
        throw(ShenScopeError(:permission, "Git history belongs to another workspace"))
    permission_decision(ctx.permissions, PermissionRequest("git-history-read", :read, "git.history",
        repository.root, "Recheck local history read")) == Deny &&
        throw(ShenScopeError(:permission, "Git history read is now denied"))
    digest(canonical(git_repository_declaration(repository.root))) == repository.declaration_hash ||
        throw(ShenScopeError(:conflict, "Git repository declaration changed during history analysis"))
    nothing
end

function git_history_environment()
    environment = Dict{String,String}()
    for name in ("PATH", "SystemRoot", "WINDIR", "TMPDIR", "TMP", "TEMP")
        haskey(ENV, name) && (environment[name] = ENV[name])
    end
    null_device = Sys.iswindows() ? "NUL" : "/dev/null"
    merge!(environment, Dict("LC_ALL" => "C", "LANG" => "C", "GIT_TERMINAL_PROMPT" => "0",
        "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => null_device,
        "GIT_CONFIG_SYSTEM" => null_device, "GIT_CONFIG_COUNT" => "0", "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_NO_LAZY_FETCH" => "1", "GIT_ATTR_NOSYSTEM" => "1", "GIT_PAGER" => "cat", "PAGER" => "cat"))
    environment
end

function git_history_path(path::AbstractString)
    value = String(path)
    isvalid(value) && !isempty(value) && ncodeunits(value) <= 4096 && !occursin('\0', value) &&
        !startswith(value, '/') && !occursin(r"^[A-Za-z]:", value) ||
        throw(ShenScopeError(:git_protocol, "Invalid historical file path"))
    parts = split(value, '/';keepempty=true)
    any(part -> part in ("", ".", ".."), parts) && throw(ShenScopeError(:git_protocol, "Noncanonical historical file path"))
    Sys.iswindows() && occursin('\\', value) && throw(ShenScopeError(:git_protocol, "Unsupported historical Windows path"))
    value
end

function git_history_public_path(path::String)
    parts = lowercase.(split(path, '/'))
    !any(part -> part in (".git", ".env", ".aws", ".ssh") || startswith(part, ".env."), parts)
end
