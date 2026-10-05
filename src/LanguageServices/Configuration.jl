function language_server_spec(value::AbstractDict)
    language_fields(value, ["name", "argv", "languages"],
        ["cwd", "initialization_options", "settings", "timeout"], "language server configuration")
    name = language_text(value["name"], "language server name", 64)
    occursin(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", name) ||
        throw(ShenScopeError(:language_config, "Invalid language server name"))
    argv = value["argv"]
    argv isa AbstractVector && 1 <= length(argv) <= 64 ||
        throw(ShenScopeError(:language_config, "Language server requires an explicit argument vector"))
    command = [language_text(argument, "language server argument", 4096; empty=index > 1) for (index, argument) in enumerate(argv)]
    sum(ncodeunits, command) <= 32*1024 || throw(ShenScopeError(:language_config, "Language server command is too large"))
    languages = value["languages"]
    languages isa AbstractVector && 1 <= length(languages) <= 32 ||
        throw(ShenScopeError(:language_config, "Invalid language server language selection"))
    selected = [language_text(language, "language ID", 64) for language in languages]
    length(unique(selected)) == length(selected) && all(language -> occursin(r"^[a-zA-Z0-9_+.-]+$", language), selected) ||
        throw(ShenScopeError(:language_config, "Repeated or invalid language IDs"))
    cwd = language_text(get(value, "cwd", "."), "language server directory", 4096)
    settings = get(value, "settings", Dict{String,Any}())
    options = get(value, "initialization_options", Dict{String,Any}())
    settings isa AbstractDict && options isa AbstractDict ||
        throw(ShenScopeError(:language_config, "Language server options and settings must be objects"))
    bounded_canonical_json(settings; maximum=128*1024, max_depth=16, max_nodes=4096)
    bounded_canonical_json(options; maximum=128*1024, max_depth=16, max_nodes=4096)
    timeout = get(value, "timeout", 30.0)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05 <= timeout <= 120 ||
        throw(ShenScopeError(:language_config, "Invalid language server request timeout"))
    normalized = Dict("name" => name, "argv" => command, "languages" => selected, "cwd" => cwd,
        "initialization_options" => options, "settings" => settings, "timeout" => Float64(timeout))
    LanguageServerSpec(name, command, cwd, selected, deepcopy(Dict{String,Any}(options)),
        deepcopy(Dict{String,Any}(settings)), Float64(timeout), digest(canonical(normalized)))
end

function language_process_target(spec::LanguageServerSpec, ctx::RuntimeContext)
    directory, _ = workspace_snapshot_path(ctx, spec.cwd; must_exist=false)
    isdir(directory) || throw(ShenScopeError(:language_config, "Language server directory must exist inside the workspace"))
    canonical(Dict("argv" => spec.argv, "cwd" => directory,
        "configuration_sha256" => spec.fingerprint, "workspace" => ctx.root))
end

function language_client_access(client::LanguageClient, ctx::RuntimeContext; process=true)
    operation_scope(client.context) == operation_scope(ctx) ||
        throw(ShenScopeError(:permission, "Language server belongs to another conversation or workspace"))
    workspace_source_checkpoint(ctx)
    permission_decision(ctx.permissions, PermissionRequest("language-service-read", :read, "language",
        ctx.root, "Read project language-service evidence")) != Deny ||
        throw(ShenScopeError(:permission, "Language-service source access was revoked"))
    if process
        agent_mode_authorize(:process, "language.process")
        permission_decision(ctx.permissions, PermissionRequest("language-service-process", :process, "language.process",
            language_process_target(client.spec, ctx), "Use the explicitly started language server")) != Deny ||
            throw(ShenScopeError(:permission, "Language server process access was revoked"))
    end
    nothing
end

function language_configuration_value(settings::AbstractDict, section)
    section === nothing && return deepcopy(settings)
    path = language_text(section, "language configuration section", 256; empty=true)
    isempty(path) && return deepcopy(settings)
    current = settings
    for key in split(path, '.')
        current isa AbstractDict && haskey(current, key) || return nothing
        current = current[key]
    end
    deepcopy(current)
end

function language_configuration_response(client::LanguageClient, params)
    language_fields(params, ["items"], String[], "language configuration request")
    items = params["items"]
    items isa AbstractVector && length(items) <= 64 ||
        throw(ShenScopeError(:language_protocol, "Too many requested language settings"))
    result = Any[]
    for item in items
        language_fields(item, String[], ["scopeUri", "section"], "language configuration scope")
        if haskey(item, "scopeUri") && item["scopeUri"] !== nothing
            language_workspace_uri(client.context, item["scopeUri"]; must_exist=false)
        end
        push!(result, language_configuration_value(client.spec.settings, get(item, "section", nothing)))
    end
    bounded_canonical_json(result; maximum=512*1024, max_depth=24, max_nodes=32_000)
    result
end
