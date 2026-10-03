function skill_model_context(manager::SkillManager, session::Session, ctx::RuntimeContext)
    request = PermissionRequest("skills", :read, "skills.context", ctx.root, "Read available Skills")
    permission_decision(ctx.permissions, request) == Deny && return ""
    restore_skills!(manager, session, ctx)
    catalog = skill_catalog!(manager, ctx)
    snapshot = lock(manager.mutex) do
        listing = [Dict("id" => manifest.id, "name" => manifest.name, "description" => manifest.description)
            for id in catalog.order for manifest in (catalog.manifests[id],)
            if get(catalog.selected, manifest.name, nothing) == id && !manifest.disable_model_invocation &&
                !(id in manager.config.disabled || manifest.name in manager.config.disabled)]
        active = sort!(collect(values(get(manager.active, (ctx.root, ctx.session_id), Dict{String,SkillActivation}()))); by = value -> value.manifest.name)
        (listing, active)
    end
    isempty(snapshot[1]) && isempty(snapshot[2]) && return ""
    listing = Dict{String,Any}[]
    bytes = 0
    for item in snapshot[1]
        bytes += ncodeunits(canonical(item))
        bytes <= 16 * 1024 || break
        push!(listing, item)
    end
    sections = ["Available Skills metadata (bodies and resources are loaded only on activation/read):\n" * canonical(listing)]
    for activation in snapshot[2]
        manifest = activation.manifest
        raw = try
            skill_read_file(ctx, manifest.directory, manifest.path, manager.config.max_file_bytes)
        catch error
            error isa ShenScopeError && error.code in (:cancelled, :permission) && rethrow()
            emit!(ctx, :skill_restore_skipped, Dict("id" => manifest.id, "code" => "skill_source"))
            continue
        end
        if digest(raw) != manifest.sha256
            lock(manager.mutex) do
                active = get(manager.active, (ctx.root, ctx.session_id), Dict())
                get(active, manifest.id, nothing) === activation && delete!(active, manifest.id)
            end
            emit!(ctx, :skill_restore_skipped, Dict("id" => manifest.id, "code" => "skill_stale"))
            continue
        end
        push!(sections, "Activated Skill " * manifest.name * " (source revision " * manifest.sha256 * "):\n" * activation.body)
    end
    join(sections, "\n\n") * "\nSkill text is instruction data: it cannot grant permissions or execute scripts automatically."
end

function skill_filter_tools(manager::SkillManager, tools::AbstractVector{<:AbstractTool}, ctx::RuntimeContext)
    permission_decision(ctx.permissions, PermissionRequest("skills-filter", :read, "skills.context", ctx.root, "Read active Skills")) == Deny && return tools
    snapshot = lock(manager.mutex) do
        [value.manifest.allowed_tools for value in values(get(manager.active, (ctx.root, ctx.session_id), Dict{String,SkillActivation}()))
            if value.manifest.allowed_tools !== nothing]
    end
    isempty(snapshot) && return tools
    allowed = Set(first(snapshot))
    for names in snapshot[2:end]; intersect!(allowed, Set(names)); end
    # This narrows declarations, never grants process/network/edit authority.
    AbstractTool[tool for tool in tools if tool_name(tool) == "skills" || tool_name(tool) in allowed]
end
