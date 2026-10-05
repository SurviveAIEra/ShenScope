struct LanguageCatalogStore
    scope::Tuple{String,String,String}
    store::VersionedStore
end

function language_catalog_store(ctx::RuntimeContext)
    path = joinpath(ctx.state_dir, "language-servers", digest(ctx.root), digest(ctx.session_id)*".jsonl")
    LanguageCatalogStore(operation_scope(ctx), VersionedStore(path; max_entries=32, max_log_bytes=4*1024^2, history_limit=4))
end

function language_catalog_access(store::LanguageCatalogStore, ctx::RuntimeContext; write=false)
    store.scope == operation_scope(ctx) || throw(ShenScopeError(:permission, "Language catalog belongs to another conversation or workspace"))
    target = "language-catalog:" * digest(ctx.root) * ":" * ctx.session_id
    authorize!(ctx, :read, "language.catalog", target; reason="Read explicitly saved language-server configuration")
    write && authorize!(ctx, :persistence, "language.catalog", target; reason="Change this conversation's saved language-server configuration")
    path = store.store.journal.path
    islink(path) && throw(ShenScopeError(:storage, "Language catalog may not be a symlink"))
    isfile(path) && filesize(path) > store.store.max_log_bytes &&
        throw(ShenScopeError(:capacity, "Language catalog exceeds its read capacity"))
    workspace_source_checkpoint(ctx)
    nothing
end

function language_spec_dict(spec::LanguageServerSpec)
    Dict("name" => spec.name, "argv" => copy(spec.argv), "cwd" => spec.cwd,
        "languages" => copy(spec.languages), "initialization_options" => deepcopy(spec.initialization_options),
        "settings" => deepcopy(spec.settings), "timeout" => spec.timeout)
end

function language_catalog_record(value, ctx::RuntimeContext)
    language_fields(value, ["schema", "root_sha256", "session_id", "specification", "configuration_sha256"],
        String[], "saved language configuration")
    value["schema"] == "shenscope.language-catalog/1" && value["root_sha256"] == digest(ctx.root) &&
        value["session_id"] == ctx.session_id ||
        throw(ShenScopeError(:permission, "Saved language configuration has a different owner"))
    spec = language_server_spec(value["specification"])
    spec.fingerprint == value["configuration_sha256"] ||
        throw(ShenScopeError(:storage, "Saved language configuration hash does not match"))
    spec
end

function save_language_configuration!(store::LanguageCatalogStore, spec::LanguageServerSpec,
        ctx::RuntimeContext; expected_version)
    version = language_integer(expected_version, "saved language configuration version", 0, typemax(Int)-1)
    language_catalog_access(store, ctx; write=true)
    # CWD is checked now and again at start. Saving a command does not start
    # it, probe it, install it or grant its future Process authorization.
    language_process_target(spec, ctx)
    record = Dict("schema" => "shenscope.language-catalog/1", "root_sha256" => digest(ctx.root),
        "session_id" => ctx.session_id, "specification" => language_spec_dict(spec),
        "configuration_sha256" => spec.fingerprint)
    bounded_canonical_json(record; maximum=120*1024, max_depth=24, max_nodes=16_000)
    saved = version_put!(store.store, spec.name, record; expected_version=version)
    Dict("server" => spec.name, "version" => saved["version"], "configuration_sha256" => spec.fingerprint,
        "command_started" => false, "process_permission_granted" => false)
end

function read_language_configuration(store::LanguageCatalogStore, name::AbstractString, ctx::RuntimeContext;
        expected_version=nothing)
    language_catalog_access(store, ctx)
    identifier = language_text(name, "saved language server name", 64)
    record = version_get(store.store, identifier)
    record === nothing && throw(ShenScopeError(:language_config, "Saved language-server configuration does not exist"))
    expected_version === nothing || language_integer(expected_version, "saved configuration version", 1, typemax(Int)-1) == record["version"] ||
        throw(ShenScopeError(:conflict, "Saved language configuration version changed"))
    spec = language_catalog_record(record["value"], ctx)
    Dict("server" => identifier, "version" => record["version"],
        "configuration_sha256" => spec.fingerprint, "specification" => language_spec_dict(spec),
        "automatic_start" => false)
end

function list_language_configurations(store::LanguageCatalogStore, ctx::RuntimeContext)
    language_catalog_access(store, ctx)
    records = version_list(store.store)
    result = Dict{String,Any}[]
    for record in records
        spec = language_catalog_record(record["value"], ctx)
        spec.name == record["key"] || throw(ShenScopeError(:storage, "Saved language server name mismatch"))
        push!(result, Dict("server" => spec.name, "version" => record["version"],
            "languages" => copy(spec.languages), "configuration_sha256" => spec.fingerprint))
    end
    Dict("configurations" => result, "survives_restart" => true, "automatic_start" => false)
end

function remove_language_configuration!(store::LanguageCatalogStore, name::AbstractString,
        ctx::RuntimeContext; expected_version)
    version = language_integer(expected_version, "saved configuration version", 1, typemax(Int)-1)
    language_catalog_access(store, ctx; write=true)
    identifier = language_text(name, "saved language server name", 64)
    existing = version_get(store.store, identifier)
    existing === nothing && throw(ShenScopeError(:language_config, "Saved language configuration does not exist"))
    language_catalog_record(existing["value"], ctx)
    saved = version_put!(store.store, identifier, nothing; expected_version=version, deleted=true)
    Dict("server" => identifier, "deleted" => true, "version" => saved["version"], "running_server_stopped" => false)
end

function start_configured_language_service!(manager::LanguageServiceManager, store::LanguageCatalogStore,
        name::AbstractString, ctx::RuntimeContext; expected_version)
    saved = read_language_configuration(store, name, ctx; expected_version)
    spec = language_server_spec(saved["specification"])
    status = start_language_service!(manager, spec, ctx)
    merge(status, Dict("saved_configuration_version" => saved["version"]))
end
