function bind_skills_session!(manager::SkillManager, session::Session, ctx::RuntimeContext)
    session.id == ctx.session_id && realpath(session.root) == ctx.root || throw(ShenScopeError(:skill_scope, "Skills session belongs to another runtime"))
    key = (ctx.root, ctx.session_id)
    lock(manager.mutex) do
        length(manager.sessions) < SKILL_MAX_SESSIONS || haskey(manager.sessions, key) ||
            throw(ShenScopeError(:skill_capacity, "Skills session capacity reached"))
        manager.sessions[key] = session
        get!(manager.activation_mutexes, key, ReentrantLock())
    end
    nothing
end

function skill_session!(manager::SkillManager, ctx::RuntimeContext)
    key = (ctx.root, ctx.session_id)
    session = lock(manager.mutex) do; get(manager.sessions, key, nothing); end
    if session === nothing
        path = joinpath(ctx.state_dir, "sessions", valid_id(ctx.session_id) * ".jsonl")
        isfile(path) || throw(ShenScopeError(:skill_scope, "Create a session before activating Skills"))
        session = load_session(ctx.state_dir, ctx.session_id)
        bind_skills_session!(manager, session, ctx)
    end
    session
end

function skill_session_mutex(manager::SkillManager, ctx::RuntimeContext)
    skill_session!(manager, ctx)
    lock(manager.mutex) do; manager.activation_mutexes[(ctx.root, ctx.session_id)]; end
end

function skill_references(active::AbstractDict)
    [Dict("id" => activation.manifest.id, "sha256" => activation.manifest.sha256, "arguments" => activation.arguments)
        for activation in sort!(collect(values(active)); by = value -> value.manifest.id)]
end

function skill_persist!(manager::SkillManager, ctx::RuntimeContext, active::AbstractDict; before_write = () -> nothing)
    session = skill_session!(manager, ctx)
    authorize!(ctx, :persistence, "skills.activation", "session:" * ctx.session_id; reason = "Save this conversation's active Skills references")
    before_write()
    session_record!(session, "metadata", Dict("active_skills" => skill_references(active)))
end

function skill_activation(manager::SkillManager, manifest::SkillManifest, ctx::RuntimeContext, arguments::String; expected_sha256 = manifest.sha256)
    isvalid(arguments) && ncodeunits(arguments) <= 16 * 1024 && !occursin('\0', arguments) ||
        throw(ShenScopeError(:skill_arguments, "Skill arguments must be bounded UTF-8 text"))
    expected_sha256 == manifest.sha256 || throw(ShenScopeError(:conflict, "Skill metadata revision changed"))
    raw = skill_read_file(ctx, manifest.directory, manifest.path, manager.config.max_file_bytes)
    digest(raw) == manifest.sha256 || throw(ShenScopeError(:skill_stale, "Skill source changed; reload before activating it"))
    _, body = skill_frontmatter(raw)
    expansion = ncodeunits(body)
    for (placeholder, value) in (("\$ARGUMENTS", arguments), ("\${SHENSCOPE_SKILL_DIR}", manifest.directory), ("\${SHENSCOPE_SESSION_ID}", ctx.session_id))
        expansion += length(findall(placeholder, body)) * max(0, ncodeunits(value) - ncodeunits(placeholder))
    end
    expansion <= 128 * 1024 || throw(ShenScopeError(:skill_size, "Expanded Skill instructions exceed capacity"))
    body = replace(body, "\$ARGUMENTS" => arguments, "\${SHENSCOPE_SKILL_DIR}" => manifest.directory,
        "\${SHENSCOPE_SESSION_ID}" => ctx.session_id)
    ncodeunits(body) <= 128 * 1024 || throw(ShenScopeError(:skill_size, "Expanded Skill instructions exceed capacity"))
    SkillActivation(manifest, arguments, body, utcstamp())
end

function activate_skill!(manager::SkillManager, identifier::AbstractString, ctx::RuntimeContext;
        arguments = "", expected_sha256 = nothing, user_requested = false)
    lock(skill_session_mutex(manager, ctx)) do
        manifest = skill_resolve(manager, ctx, identifier)
        user_requested ? manifest.user_invocable || throw(ShenScopeError(:skill_invocation, "Skill is not user invocable")) :
            !manifest.disable_model_invocation || throw(ShenScopeError(:skill_invocation, "Skill requires explicit user invocation"))
        activation = skill_activation(manager, manifest, ctx, String(arguments);
            expected_sha256 = expected_sha256 === nothing ? manifest.sha256 : expected_sha256)
        key = (ctx.root, ctx.session_id)
        next = lock(manager.mutex) do; copy(get(manager.active, key, Dict{String,SkillActivation}())); end
        length(next) < SKILL_MAX_ACTIVATIONS || haskey(next, manifest.id) || throw(ShenScopeError(:skill_capacity, "Active Skills capacity reached"))
        next[manifest.id] = activation
        sum(ncodeunits(value.body) for value in values(next); init = 0) <= 256 * 1024 || throw(ShenScopeError(:skill_size, "Active Skills instruction budget exceeded"))
        skill_persist!(manager, ctx, next; before_write = () -> begin
            request = PermissionRequest("skill-revision", :read, "skills.activate", manifest.path, "Verify the approved Skill revision")
            permission_decision(ctx.permissions, request) == Deny && throw(ShenScopeError(:permission, "Skill source access was revoked"))
            raw = skill_read_file(ctx, manifest.directory, manifest.path, manager.config.max_file_bytes; authorized = true)
            digest(raw) == manifest.sha256 || throw(ShenScopeError(:skill_stale, "Skill source changed while awaiting approval"))
            lock(manager.mutex) do
                catalog = get(manager.catalogs, ctx.root, nothing)
                current = catalog === nothing ? nothing : get(catalog.manifests, manifest.id, nothing)
                current !== nothing && current.sha256 == manifest.sha256 || throw(ShenScopeError(:conflict, "Skill catalog changed while awaiting approval"))
            end
        end)
        lock(manager.mutex) do; manager.active[key] = next; end
        emit!(ctx, :skill_activated, Dict("id" => manifest.id, "name" => manifest.name, "sha256" => manifest.sha256))
        Dict("id" => manifest.id, "name" => manifest.name, "sha256" => manifest.sha256, "loaded_at" => activation.loaded_at,
            "session_id" => ctx.session_id, "body" => activation.body)
    end
end

function deactivate_skill!(manager::SkillManager, identifier::AbstractString, ctx::RuntimeContext)
    lock(skill_session_mutex(manager, ctx)) do
        key = (ctx.root, ctx.session_id)
        next = lock(manager.mutex) do; copy(get(manager.active, key, Dict{String,SkillActivation}())); end
        selected = [id for (id, value) in next if id == identifier || value.manifest.name == identifier]
        for id in selected; delete!(next, id); end
        skill_persist!(manager, ctx, next)
        lock(manager.mutex) do; manager.active[key] = next; end
        emit!(ctx, :skill_deactivated, Dict("ids" => selected))
        Dict("deactivated" => selected, "session_id" => ctx.session_id)
    end
end

function restore_skills!(manager::SkillManager, session::Session, ctx::RuntimeContext)
    bind_skills_session!(manager, session, ctx)
    references = get(session.metadata, "active_skills", Any[])
    references isa AbstractVector && length(references) <= SKILL_MAX_ACTIVATIONS || throw(ShenScopeError(:skill_state, "Invalid saved Skills references"))
    isempty(references) && return
    lock(skill_session_mutex(manager, ctx)) do
        key = (ctx.root, ctx.session_id)
        for reference in references
            reference isa AbstractDict && all(k -> k in ("id", "sha256", "arguments"), keys(reference)) ||
                throw(ShenScopeError(:skill_state, "Invalid saved Skill reference"))
            id = get(reference, "id", nothing)
            hash = get(reference, "sha256", nothing)
            arguments = get(reference, "arguments", "")
            id isa AbstractString && hash isa AbstractString && arguments isa AbstractString || throw(ShenScopeError(:skill_state, "Invalid saved Skill reference fields"))
            current = lock(manager.mutex) do; get(get(manager.active, key, Dict()), id, nothing); end
            current !== nothing && current.manifest.sha256 == hash && continue
            try
                manifest = skill_resolve(manager, ctx, id)
                activation = skill_activation(manager, manifest, ctx, String(arguments); expected_sha256 = hash)
                lock(manager.mutex) do
                    active = get!(manager.active, key, Dict{String,SkillActivation}())
                    sum(ncodeunits(value.body) for value in values(active); init = 0) + ncodeunits(activation.body) <= 256 * 1024 ||
                        throw(ShenScopeError(:skill_size, "Restored Skills instruction budget exceeded"))
                    active[manifest.id] = activation
                end
            catch error
                error isa ShenScopeError && error.code in (:cancelled, :permission) && rethrow()
                emit!(ctx, :skill_restore_skipped, Dict("id" => id, "code" => error isa ShenScopeError ? String(error.code) : "skill_state"))
            end
        end
    end
    nothing
end

function skill_read_source(manager::SkillManager, identifier::AbstractString, ctx::RuntimeContext)
    manifest = skill_resolve(manager, ctx, identifier; allow_disabled = true)
    raw = skill_read_file(ctx, manifest.directory, manifest.path, manager.config.max_file_bytes)
    Dict("id" => manifest.id, "path" => manifest.path, "sha256" => digest(raw), "text" => raw, "stale" => digest(raw) != manifest.sha256)
end

function skill_read_resource(manager::SkillManager, identifier::AbstractString, relative::AbstractString, ctx::RuntimeContext)
    manifest = skill_resolve(manager, ctx, identifier)
    !isabspath(relative) && ncodeunits(relative) <= 4096 && !isempty(relative) && !occursin('\0', relative) || throw(ShenScopeError(:skill_resource, "Skill resources require a relative path"))
    path = workspace_path(manifest.directory, relative; must_exist = true)
    text = skill_read_file(ctx, manifest.directory, String(relative), manager.config.max_resource_bytes)
    Dict("id" => manifest.id, "path" => path, "relative_path" => String(relative), "sha256" => digest(text), "text" => text)
end

function cleanup_skills!(manager::SkillManager; root = nothing, session_id = nothing)
    jobs = lock(manager.mutex) do
        [job for job in values(manager.jobs) if (root === nothing || job.context.root == root) && (session_id === nothing || job.context.session_id == session_id)]
    end
    for job in jobs; cancel!(job.context.cancellation, "Skills owner stopped"); end
    for job in jobs; job.task !== nothing && job.task !== current_task() && try wait(job.task) catch end; end
    lock(manager.mutex) do
        for key in collect(keys(manager.sessions))
            (root === nothing || key[1] == root) && (session_id === nothing || key[2] == session_id) || continue
            delete!(manager.active, key); delete!(manager.sessions, key); delete!(manager.activation_mutexes, key)
        end
        if root === nothing && session_id === nothing
            empty!(manager.catalogs)
            empty!(manager.jobs)
        end
    end
    nothing
end
