server_skills_tool(server::CoreServer) = only(tool for tool in server.tools if tool isa SkillsTool)

function skill_job_view(job::SkillJob)
    Dict("job_id" => job.id, "action" => job.action, "status" => String(job.status), "result" => deepcopy(job.result), "error" => job.error)
end

function skill_rpc_job(manager::SkillManager, id::String, ctx::RuntimeContext)
    lock(manager.mutex) do
        job = get(manager.jobs, id, nothing)
        job === nothing && throw(ShenScopeError(:skill_job, "Skills job does not exist"))
        job.context.root == ctx.root && job.context.session_id == ctx.session_id || throw(ShenScopeError(:permission, "Skills job belongs to another session"))
        job
    end
end

function skill_source_path(server::CoreServer, manager::SkillManager, job::SkillJob)
    job.status == :complete && job.action == "source" && !job.opened && time() - job.finished_at <= 300 ||
        throw(ShenScopeError(:skill_job, "Source opening requires a recent completed source read"))
    check_cancelled(job.context.cancellation)
    policy = permissions_from_config(server.config)
    request = PermissionRequest("source", :read, "skills.open_source", job.result["path"], "Open an approved Skill source")
    permission_decision(policy, request) == Deny && throw(ShenScopeError(:permission, "Opening Skill source is denied"))
    permission_decision(job.context.permissions, request) == Deny && throw(ShenScopeError(:permission, "Opening Skill source is denied"))
    catalog = lock(manager.mutex) do; get(manager.catalogs, server.root, nothing); end
    catalog !== nothing || throw(ShenScopeError(:skill_stale, "Skills catalog was replaced"))
    manifest = get(catalog.manifests, job.result["id"], nothing)
    manifest !== nothing && manifest.path == job.result["path"] || throw(ShenScopeError(:skill_stale, "Skill source identity changed"))
    raw = skill_read_file(job.context, manifest.directory, manifest.path, manager.config.max_file_bytes; authorized = true)
    digest(raw) == job.result["sha256"] || throw(ShenScopeError(:skill_stale, "Skill source changed after approval"))
    lock(manager.mutex) do
        job.opened && throw(ShenScopeError(:skill_job, "Source opening was already consumed"))
        job.opened = true
    end
    Dict("path" => manifest.path, "sha256" => job.result["sha256"])
end

function skills_rpc(server::CoreServer, method::String, params::AbstractDict)
    tool = server_skills_tool(server)
    manager = tool.manager
    session = server_session(server, params)
    prior = get(server.contexts, session.id, nothing)
    if method == "skills/query"
        policy = prior === nothing ? permissions_from_config(server.config) : prior.permissions
        request = PermissionRequest("skills-query", :read, "skills.query", server.root, "Read Skills metadata")
        permission_decision(policy, request) == Allow || throw(ShenScopeError(:permission, "Use skills/start for permissioned catalog discovery"))
        ctx = RuntimeContext(server.root; session_id = session.id, state_dir = server.state_dir, permissions = policy)
        return lock(manager.mutex) do
            catalog = get(manager.catalogs, server.root, nothing)
            roots = Dict("project" => copy(manager.config.project_roots), "user" => copy(manager.config.user_roots))
            catalog === nothing && return Dict("indexed" => false, "roots" => roots)
            for paths in (manager.config.project_roots, manager.config.user_roots), path in paths
                target = normpath(isabspath(path) ? path : joinpath(server.root, path))
                isdir(target) || continue
                permission_decision(policy, PermissionRequest("skills-root", :read, "skills.query", target, "Read Skills metadata")) == Allow ||
                    throw(ShenScopeError(:permission, "Use skills/start for permissioned catalog discovery"))
            end
            Dict("indexed" => true, "roots" => roots, "generation" => catalog.generation, "truncated" => catalog.truncated, "diagnostics" => deepcopy(catalog.diagnostics),
                "skills" => [skill_manifest_view(catalog.manifests[id], catalog, manager, ctx) for id in catalog.order])
        end
    elseif method in ("skills/job", "skills/cancel_job", "skills/source_path")
        ctx = RuntimeContext(server.root; session_id = session.id, state_dir = server.state_dir)
        job = skill_rpc_job(manager, rpc_string(params, "job_id"; max_bytes = 128), ctx)
        method == "skills/source_path" && return skill_source_path(server, manager, job)
        method == "skills/cancel_job" && cancel!(job.context.cancellation, "Skills operation cancelled")
        return lock(manager.mutex) do; skill_job_view(job); end
    elseif method == "skills/start"
        arguments = Dict{String,Any}(key => value for (key, value) in params if key != "session_id")
        validate_tool_arguments(tool, arguments)
        action = arguments["action"]
        action in ("activate", "deactivate") && haskey(server.runs, session.id) &&
            throw(ShenScopeError(:skill_busy, "Change active Skills between agent runs"))
        owner = prior === nothing || iscancelled(prior.cancellation) ? server_context(server, session.id) : prior
        ctx = child_context(owner)
        action in ("activate", "deactivate") && bind_skills_session!(manager, session, ctx)
        job = SkillJob(string(uuid4()), action, ctx, :running, nothing, nothing, nothing, 0.0, 0, false)
        lock(manager.mutex) do
            count(value -> value.status == :running, values(manager.jobs)) < 8 || throw(ShenScopeError(:skill_capacity, "Skills operation concurrency limit reached"))
            any(value -> value.status == :running && value.context.session_id == session.id, values(manager.jobs)) &&
                throw(ShenScopeError(:skill_busy, "A Skills operation is already running in this conversation"))
            if length(manager.jobs) >= 64
                completed = sort!([value for value in values(manager.jobs) if value.status != :running]; by = value -> value.finished_at)
                isempty(completed) && throw(ShenScopeError(:skill_capacity, "Skills job capacity reached"))
                delete!(manager.jobs, first(completed).id)
            end
            manager.jobs[job.id] = job
        end
        job.task = @async with_context(ctx) do
            try
                result = execute(tool, arguments, ctx; user_requested = true)
                bytes = ncodeunits(canonical(result))
                bytes <= 4 * 1024 * 1024 || throw(ShenScopeError(:skill_size, "Skills result exceeds transport capacity"))
                lock(manager.mutex) do
                    completed = sort!([value for value in values(manager.jobs) if value.status != :running && value.id != job.id]; by = value -> value.finished_at)
                    total = sum(value.result_bytes for value in completed; init = 0)
                    for prior_job in completed
                        total + bytes <= 16 * 1024 * 1024 && break
                        delete!(manager.jobs, prior_job.id); total -= prior_job.result_bytes
                    end
                    job.result = result; job.result_bytes = bytes; job.status = :complete; job.finished_at = time()
                end
                emit!(ctx, :skills_job_completed, skill_job_view(job))
            catch error
                lock(manager.mutex) do
                    job.status = iscancelled(ctx.cancellation) ? :cancelled : :failed
                    job.error = error isa ShenScopeError ? error.message : "Skills operation failed"
                    job.finished_at = time()
                end
                emit!(ctx, :skills_job_failed, skill_job_view(job))
            end
        end
        return Dict("job_id" => job.id, "started" => true)
    end
    throw(RPCFault(-32601, "Skills method not found"))
end
