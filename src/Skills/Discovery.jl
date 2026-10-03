function skill_root_path(ctx::RuntimeContext, path::String, scope::Symbol)
    original = normpath(isabspath(path) ? path : joinpath(ctx.root, path))
    isdir(original) && realpath(original) != original && throw(ShenScopeError(:permission, "Skills root contains a symlink"))
    resolved = scope == :project ? workspace_path(ctx.root, path) : normpath(path)
    resolved in (dirname(resolved), homedir()) && throw(ShenScopeError(:skill_config, "A Skills root cannot be a filesystem or home root"))
    any(part -> lowercase(part) in (".git", ".ssh", ".aws", ".env") || startswith(lowercase(part), ".env."), splitpath(resolved)) &&
        throw(ShenScopeError(:permission, "Protected Skills root"))
    islink(resolved) && throw(ShenScopeError(:permission, "Skills root symlinks are not supported"))
    if isdir(resolved)
        actual = realpath(resolved)
        actual == resolved || throw(ShenScopeError(:permission, "Skills root contains a symlink"))
        authorize!(ctx, :read, "skills.discover", actual; reason = "Discover configured Skills metadata")
    end
    resolved
end

function skill_read_file(ctx::RuntimeContext, root::String, path::String, maximum::Int; authorized = false)
    read_scoped_text(ctx, root, path, maximum; authorized, tool="skills.read", reason="Read a Skills source or resource",
        size_error=:skill_size, encoding_error=:skill_encoding)
end

function discover_skills(config::SkillConfig, ctx::RuntimeContext; generation = 1)
    manifests = Dict{String,SkillManifest}()
    selected = Dict{String,String}()
    order = String[]
    diagnostics = Dict{String,Any}[]
    entries = 0
    truncated = false
    visited = Set{String}()
    report = function (path, code; severity = "error", name = nothing)
        length(diagnostics) < 256 && push!(diagnostics, skill_diagnostic(path, code; severity, name))
    end
    roots = vcat([(path, :project) for path in config.project_roots], [(path, :user) for path in config.user_roots])
    for (source, scope) in roots
        root = try
            skill_root_path(ctx, source, scope)
        catch error
            error isa ShenScopeError && error.code in (:permission, :cancelled) && rethrow()
            report(source, error isa ShenScopeError ? error.code : :skill_scan)
            continue
        end
        isdir(root) || continue
        stack = [(root, 0)]
        while !isempty(stack)
            check_cancelled(ctx.cancellation)
            directory, depth = pop!(stack)
            directory in visited && continue
            push!(visited, directory)
            entries += 1
            if entries > config.max_entries
                truncated = true
                report(directory, :skill_capacity)
                break
            end
            source_path = joinpath(directory, "SKILL.md")
            if isfile(source_path) && !islink(source_path)
                if length(manifests) >= config.max_skills
                    truncated = true
                    report(source_path, :skill_capacity)
                    break
                end
                try
                    raw = skill_read_file(ctx, root, source_path, config.max_file_bytes)
                    manifest = skill_manifest(raw, source_path, scope)
                    if haskey(manifests, manifest.id)
                        manifests[manifest.id].path == manifest.path || throw(ShenScopeError(:skill_identity, "Skills identity collision"))
                    else
                        manifests[manifest.id] = manifest
                        push!(order, manifest.id)
                        if haskey(selected, manifest.name)
                            report(source_path, :skill_shadowed; severity = "warning", name = manifest.name)
                        else
                            selected[manifest.name] = manifest.id
                        end
                    end
                    basename(directory) != manifest.name && report(source_path, :skill_directory_name; severity = "warning", name = manifest.name)
                    known = Set(["name", "description", "license", "compatibility", "metadata", "allowed-tools", "disable-model-invocation", "user-invocable", "argument-hint"])
                    any(key -> !(key in known), keys(manifest.metadata)) && report(source_path, :skill_unknown_metadata; severity = "warning", name = manifest.name)
                catch error
                    error isa ShenScopeError && error.code in (:permission, :cancelled) && rethrow()
                    report(source_path, error isa ShenScopeError ? error.code : :skill_parse)
                end
                continue
            elseif islink(source_path)
                report(source_path, :skill_symlink)
                continue
            end
            depth < config.max_depth || continue
            children = try
                readdir(directory; join = true, sort = true)
            catch
                report(directory, :skill_scan)
                continue
            end
            if length(children) > config.max_entries - entries
                truncated = true
                report(directory, :skill_capacity)
                break
            end
            entries += length(children)
            for child in reverse(children)
                name = basename(child)
                (startswith(name, ".") || name in ("node_modules", "vendor", "build", "dist") || islink(child)) && continue
                isdir(child) && push!(stack, (child, depth + 1))
            end
        end
        truncated && break
    end
    SkillCatalog(ctx.root, generation, manifests, selected, order, diagnostics, entries, truncated, utcstamp())
end

function skill_catalog!(manager::SkillManager, ctx::RuntimeContext; reload = false)
    authorize!(ctx, :read, "skills.catalog", ctx.root; reason = "Read the workspace Skills catalog")
    for (paths, scope) in ((manager.config.project_roots, :project), (manager.config.user_roots, :user)), path in paths
        skill_root_path(ctx, path, scope)
    end
    cached = lock(manager.mutex) do; get(manager.catalogs, ctx.root, nothing); end
    !reload && cached !== nothing && return cached
    lock(manager.discovery_mutex) do
        cached = lock(manager.mutex) do; get(manager.catalogs, ctx.root, nothing); end
        !reload && cached !== nothing && return cached
        config = manager.config
        generation = cached === nothing ? 1 : cached.generation + 1
        catalog = discover_skills(config, ctx; generation)
        lock(manager.mutex) do
            length(manager.catalogs) < SKILL_MAX_CATALOGS || haskey(manager.catalogs, ctx.root) ||
                throw(ShenScopeError(:skill_capacity, "Skills workspace catalog capacity reached"))
            manager.config === config || throw(ShenScopeError(:conflict, "Skills configuration changed during discovery"))
            manager.catalogs[ctx.root] = catalog
            for (key, active) in manager.active
                key[1] == ctx.root || continue
                for id in collect(keys(active))
                    current = get(catalog.manifests, id, nothing)
                    (current === nothing || current.sha256 != active[id].manifest.sha256 ||
                        id in config.disabled || current.name in config.disabled) && delete!(active, id)
                end
            end
        end
        emit!(ctx, :skills_reloaded, Dict("generation" => catalog.generation, "count" => length(catalog.manifests),
            "truncated" => catalog.truncated, "diagnostics" => length(catalog.diagnostics)))
        catalog
    end
end

function skills_list(manager::SkillManager, ctx::RuntimeContext; reload = false)
    catalog = skill_catalog!(manager, ctx; reload)
    lock(manager.mutex) do
        Dict("generation" => catalog.generation, "loaded_at" => catalog.loaded_at, "truncated" => catalog.truncated,
            "roots" => Dict("project" => copy(manager.config.project_roots), "user" => copy(manager.config.user_roots)),
            "entries" => catalog.entries, "diagnostics" => deepcopy(catalog.diagnostics),
            "skills" => [skill_manifest_view(catalog.manifests[id], catalog, manager, ctx) for id in catalog.order])
    end
end

function skill_resolve(manager::SkillManager, ctx::RuntimeContext, identifier::AbstractString; allow_disabled = false)
    catalog = skill_catalog!(manager, ctx)
    id = haskey(catalog.manifests, identifier) ? String(identifier) : get(catalog.selected, identifier, "")
    manifest = get(catalog.manifests, id, nothing)
    manifest === nothing && throw(ShenScopeError(:skill_missing, "Skill is not in this workspace catalog"))
    !allow_disabled && (manifest.id in manager.config.disabled || manifest.name in manager.config.disabled) ?
        throw(ShenScopeError(:skill_disabled, "Skill is disabled")) : manifest
end
