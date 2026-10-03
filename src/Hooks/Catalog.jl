function hook_source_location(ctx::RuntimeContext, value::String, scope::Symbol)
    original = normpath(isabspath(value) ? value : joinpath(ctx.root, value))
    target = scope == :project ? workspace_path(ctx.root, value) : original
    target == original && !islink(original) || throw(ShenScopeError(:permission, "Hook source symlinks are not supported"))
    if ispath(target)
        isfile(target) && realpath(target) == target || throw(ShenScopeError(:hook_config, "Hook source must be a regular file without symlinks"))
        workspace_path(scope == :project ? ctx.root : dirname(target), target; must_exist=true)
    end
    target
end

function hook_read_source(ctx::RuntimeContext, root::String, path::String; authorized=false, maximum=128 * 1024)
    any(part -> lowercase(part) in (".git",".aws",".ssh",".env") || startswith(lowercase(part),".env."),splitpath(path)) &&
        throw(ShenScopeError(:permission,"Protected Hook configuration source"))
    read_scoped_text(ctx, root, path, maximum; authorized, tool="hooks.source", reason="Read an explicit Hook configuration source",
        size_error=:hook_size, encoding_error=:hook_encoding)
end

function hook_source_entries(raw::String)
    document = try TOML.parse(raw) catch; throw(ShenScopeError(:hook_config, "Malformed Hook source TOML")); end
    all(key -> key == "hooks", keys(document)) || throw(ShenScopeError(:hook_config, "Hook source requires only [[hooks]] declarations"))
    entries = get(document, "hooks", [])
    entries isa AbstractVector && length(entries) <= 256 || throw(ShenScopeError(:hook_config, "Hook source declarations exceed capacity"))
    all(value -> value isa AbstractDict, entries) || throw(ShenScopeError(:hook_config, "Hook declarations must be objects"))
    entries
end

function hook_catalog!(manager::HookManager, ctx::RuntimeContext; reload=false)
    check_cancelled(ctx.cancellation)
    cached = lock(manager.mutex) do; get(manager.catalogs, ctx.root, nothing); end
    if cached !== nothing && !reload
        cached.config_sha256 == hook_config_digest(manager.config) || throw(ShenScopeError(:hook_stale, "Hook configuration changed; reload its catalog"))
        return cached
    end
    lock(manager.discovery_mutex) do
        config = manager.config
        fingerprint = hook_config_digest(config)
        cached = lock(manager.mutex) do; get(manager.catalogs, ctx.root, nothing); end
        !reload && cached !== nothing && cached.config_sha256 == fingerprint && return cached
        specs = HookSpec[]
        sources = Dict{String,String}()
        if !isempty(config.entries)
            source = manager.config_source
            root = source === nothing ? ctx.root : dirname(source)
            sha = source === nothing ? fingerprint : digest(hook_read_source(ctx, root, source; maximum=1024 * 1024))
            source !== nothing && sha != manager.config_source_digest && throw(ShenScopeError(:hook_stale, "Core configuration changed externally; reload Core configuration"))
            source !== nothing && (sources[source] = sha)
            for declaration in config.entries
                push!(specs, hook_spec(declaration; scope=:config, source, source_root=root, source_sha256=sha))
            end
        end
        for (paths, scope) in ((config.project_files, :project), (config.user_files, :user)), value in paths
            path = hook_source_location(ctx, value, scope)
            isfile(path) || continue
            haskey(sources, path) && throw(ShenScopeError(:hook_config, "Hook source is configured more than once"))
            root = scope == :project ? ctx.root : dirname(path)
            raw = hook_read_source(ctx, root, path)
            sha = digest(raw); sources[path] = sha
            names = Set{String}()
            for declaration in hook_source_entries(raw)
                spec = hook_spec(declaration; scope, source=path, source_root=root, source_sha256=sha)
                spec.name in names && throw(ShenScopeError(:hook_config, "Duplicate Hook names within one source"))
                push!(names, spec.name); push!(specs, spec)
                length(specs) <= config.max_hooks || throw(ShenScopeError(:hook_capacity, "Hook catalog exceeds capacity"))
            end
        end
        length(unique(spec.id for spec in specs)) == length(specs) || throw(ShenScopeError(:hook_identity, "Hook declaration identity collision"))
        catalog = HookCatalog(ctx.root, cached === nothing ? 1 : cached.generation + 1, fingerprint, specs, sources, utcstamp())
        lock(manager.mutex) do
            fingerprint == hook_config_digest(manager.config) || throw(ShenScopeError(:hook_stale, "Hook configuration changed during discovery"))
            length(manager.catalogs) < 32 || haskey(manager.catalogs, ctx.root) || throw(ShenScopeError(:hook_capacity, "Hook workspace capacity reached"))
            manager.catalogs[ctx.root] = catalog
        end
        catalog
    end
end

function hook_enabled(manager::HookManager, spec::HookSpec)
    manager.config.enabled && spec.enabled && !(spec.id in manager.config.disabled || spec.name in manager.config.disabled)
end

function hook_find(catalog::HookCatalog, name::AbstractString)
    matches = [spec for spec in catalog.specs if spec.id == name || spec.name == name]
    isempty(matches) && throw(ShenScopeError(:hook_missing, "Hook does not exist"))
    length(matches) == 1 || throw(ShenScopeError(:hook_identity, "Hook name is ambiguous; select its source ID"))
    only(matches)
end

function validate_hook_source!(manager::HookManager, catalog::HookCatalog, spec::HookSpec, ctx::RuntimeContext; authorized=false)
    current = lock(manager.mutex) do; get(manager.catalogs, ctx.root, nothing); end
    current === catalog && catalog.config_sha256 == hook_config_digest(manager.config) && hook_enabled(manager, spec) ||
        throw(ShenScopeError(:hook_stale, "Hook declaration was replaced or disabled"))
    if spec.source !== nothing
        raw = hook_read_source(ctx, spec.source_root, spec.source; authorized,
            maximum=spec.scope == :config ? 1024 * 1024 : 128 * 1024)
        digest(raw) == spec.source_sha256 || throw(ShenScopeError(:hook_stale, "Hook source changed; reload and review its new declaration"))
    end
    nothing
end

function hook_spec_view(manager::HookManager, catalog::HookCatalog, spec::HookSpec, ctx::RuntimeContext)
    recent = lock(manager.mutex) do
        index = findlast(item -> item["hook_id"] == spec.id && item["session_id"] == ctx.session_id && item["root"] == ctx.root, manager.history)
        index === nothing ? nothing : deepcopy(manager.history[index])
    end
    Dict("id"=>spec.id, "name"=>spec.name, "point"=>HOOK_POINT_NAMES[spec.point], "scope"=>String(spec.scope),
        "source"=>spec.source, "source_sha256"=>spec.source_sha256, "declaration_sha256"=>spec.declaration_sha256,
        "enabled"=>hook_enabled(manager, spec), "declared_enabled"=>spec.enabled, "argv"=>copy(spec.argv), "cwd"=>spec.cwd, "timeout"=>spec.timeout,
        "on_failure"=>String(spec.on_failure), "allow_context"=>spec.allow_context, "replay_safe"=>spec.replay_safe, "tools"=>copy(spec.tools),
        "environment_sources"=>copy(spec.environment_env), "recent"=>recent)
end

function hooks_list(manager::HookManager, ctx::RuntimeContext; reload=false)
    authorize!(ctx, :read, "hooks.catalog", ctx.root;reason="Read the workspace Hook catalog")
    catalog = hook_catalog!(manager, ctx; reload)
    for spec in catalog.specs
        spec.source === nothing && continue
        authorize!(ctx, :read, "hooks.catalog", spec.source; reason="Read Hook metadata")
    end
    Dict("indexed"=>true, "enabled"=>manager.config.enabled, "generation"=>catalog.generation,
        "sources"=>copy(catalog.sources), "points"=>[HOOK_POINT_NAMES[point] for point in instances(HookPoint)],
        "hooks"=>[hook_spec_view(manager, catalog, spec, ctx) for spec in catalog.specs])
end

function hooks_read_configuration(manager::HookManager, name::AbstractString, ctx::RuntimeContext)
    catalog = hook_catalog!(manager, ctx)
    spec = hook_find(catalog, name)
    spec.source === nothing && throw(ShenScopeError(:hook_source, "Inline Hook has no configuration file"))
    raw = hook_read_source(ctx, spec.source_root, spec.source; maximum=spec.scope == :config ? 1024 * 1024 : 128 * 1024)
    digest(raw) == spec.source_sha256 || throw(ShenScopeError(:hook_stale, "Hook configuration changed; reload its catalog"))
    Dict("id"=>spec.id, "path"=>spec.source, "sha256"=>spec.source_sha256, "text"=>raw)
end
