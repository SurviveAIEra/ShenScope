function hook_string(value, label; maximum=4096, empty=false)
    value isa AbstractString && isvalid(value) && !occursin('\0', value) &&
        (empty || !isempty(strip(value))) && ncodeunits(value) <= maximum ||
        throw(ShenScopeError(:hook_config, "Invalid Hook " * label))
    String(value)
end

function hook_strings(value, label; maximum=16, item_bytes=4096)
    value isa AbstractVector && length(value) <= maximum || throw(ShenScopeError(:hook_config, "Hook " * label * " exceeds capacity"))
    result = [hook_string(item, label; maximum=item_bytes) for item in value]
    length(unique(result)) == length(result) || throw(ShenScopeError(:hook_config, "Duplicate Hook " * label))
    result
end

function hook_integer(value, label, lower, upper)
    value isa Int && lower <= value <= upper || throw(ShenScopeError(:hook_config, "Invalid Hook " * label))
    value
end

function hook_boolean(value, label)
    value isa Bool || throw(ShenScopeError(:hook_config, "Hook " * label * " must be boolean"))
    value
end

function hook_spec(raw::AbstractDict; scope=:config, source=nothing, source_root="", source_sha256="")
    fields = Set(["name", "point", "argv", "cwd", "timeout", "output_limit", "enabled", "tools", "on_failure", "allow_context", "replay_safe", "environment_env"])
    all(key -> key in fields, keys(raw)) || throw(ShenScopeError(:hook_config, "Unknown Hook declaration field"))
    name = hook_string(get(raw, "name", nothing), "name"; maximum=64)
    occursin(r"^[a-z][a-z0-9_-]{0,63}$", name) || throw(ShenScopeError(:hook_config, "Hook names must be lowercase identifiers"))
    point = hook_point(get(raw, "point", nothing))
    argv_raw = get(raw, "argv", nothing)
    argv_raw isa AbstractVector && 1 <= length(argv_raw) <= 128 || throw(ShenScopeError(:hook_config, "Hook argv requires 1–128 arguments"))
    argv = [hook_string(value, "argument"; maximum=65536, empty=index>1) for (index, value) in enumerate(argv_raw)]
    sum(ncodeunits, argv; init=0) <= 128 * 1024 || throw(ShenScopeError(:hook_config, "Hook argument vector exceeds capacity"))
    cwd = hook_string(get(raw, "cwd", "."), "working directory")
    timeout = get(raw, "timeout", 10.0)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05 <= timeout <= 300 ||
        throw(ShenScopeError(:hook_config, "Hook timeout must be 0.05–300 seconds"))
    output_limit = hook_integer(get(raw, "output_limit", 32 * 1024), "output limit", 256, 256 * 1024)
    tools = hook_strings(get(raw, "tools", []), "tool matchers"; maximum=32, item_bytes=128)
    !isempty(tools) && !(point in (HookBeforeTool, HookAfterTool, HookAfterEdit, HookAfterTest)) &&
        throw(ShenScopeError(:hook_config, "Tool matchers require a tool lifecycle point"))
    failure = Symbol(hook_string(get(raw, "on_failure", "warn"), "failure behavior"; maximum=16))
    failure in (:warn, :deny) || throw(ShenScopeError(:hook_config, "Hook failure behavior must be warn or deny"))
    failure == :deny && !(point in HOOK_PRE_POINTS) && throw(ShenScopeError(:hook_config, "Post-effect Hooks cannot undo completed operations"))
    environment_raw = get(raw, "environment_env", Dict())
    environment_raw isa AbstractDict && length(environment_raw) <= 16 || throw(ShenScopeError(:hook_config, "Hook environment bindings exceed capacity"))
    environment = Dict{String,String}()
    for (environment_name, source_name) in environment_raw
        key = hook_string(environment_name, "environment name"; maximum=128)
        binding = hook_string(source_name, "environment source"; maximum=128)
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", key) && occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", binding) &&
            !startswith(uppercase(key), "SHENSCOPE_") || throw(ShenScopeError(:hook_config, "Invalid Hook environment binding"))
        environment[key] = binding
    end
    enabled = hook_boolean(get(raw, "enabled", true), "enabled state")
    context = hook_boolean(get(raw, "allow_context", false), "context permission")
    context && point == HookSessionEnd && throw(ShenScopeError(:hook_config, "Session-end context has no subsequent request"))
    identity = String(scope) * ":" * something(source, "inline") * ":" * name
    HookSpec("hook-" * digest(identity)[1:24], name, point, argv, cwd, Float64(timeout), output_limit, enabled,
        tools, failure, context, hook_boolean(get(raw,"replay_safe",false),"replay safety"), environment, scope, source, source_root, source_sha256, digest(canonical(raw)))
end

function hook_config(config::AbstractDict)
    section = get(config, "hooks", Dict())
    fields = Set(["enabled", "project_files", "user_files", "entries", "disabled", "max_hooks", "max_history"])
    section isa AbstractDict && all(key -> key in fields, keys(section)) || throw(ShenScopeError(:hook_config, "Invalid Hooks configuration section"))
    project = hook_strings(get(section, "project_files", [".shenscope/hooks.toml"]), "project sources"; maximum=8)
    user = hook_strings(get(section, "user_files", []), "user sources"; maximum=8)
    all(isabspath, user) || throw(ShenScopeError(:hook_config, "User Hook sources must be absolute paths"))
    maximum = hook_integer(get(section, "max_hooks", 128), "catalog size", 1, 256)
    history = hook_integer(get(section, "max_history", 256), "history size", 1, 1024)
    disabled = hook_strings(get(section, "disabled", []), "disabled names"; maximum=512, item_bytes=128)
    entries = get(section, "entries", [])
    entries isa AbstractVector && length(entries) <= maximum || throw(ShenScopeError(:hook_config, "Inline Hook declarations exceed capacity"))
    declarations = Dict{String,Any}[]
    names = Set{String}()
    for raw in entries
        raw isa AbstractDict || throw(ShenScopeError(:hook_config, "Hook entries must be objects"))
        spec = hook_spec(raw)
        spec.name in names && throw(ShenScopeError(:hook_config, "Duplicate inline Hook names"))
        push!(names, spec.name); push!(declarations, deepcopy(Dict{String,Any}(raw)))
    end
    HookConfig(hook_boolean(get(section, "enabled", true), "global enabled state"), project, user, declarations, disabled, maximum, history)
end

function hook_config_digest(config::HookConfig)
    digest(canonical(Dict("enabled"=>config.enabled, "project_files"=>config.project_files, "user_files"=>config.user_files,
        "entries"=>config.entries, "disabled"=>config.disabled, "max_hooks"=>config.max_hooks, "max_history"=>config.max_history)))
end

function HookManager(config::AbstractDict=Dict(); config_source=nothing, credential_lookup=key->get(ENV, key, ""))
    path = config_source === nothing ? nothing : abspath(config_source)
    source_digest = path === nothing || !isfile(path) ? nothing : begin
        filesize(path) <= 1024 * 1024 || throw(ShenScopeError(:hook_config, "Core configuration exceeds capacity"))
        bytes=open(input -> read(input,1024 * 1024 + 1),path,"r")
        length(bytes) <= 1024 * 1024 || throw(ShenScopeError(:hook_config,"Core configuration exceeds capacity"))
        digest(String(bytes))
    end
    HookManager(hook_config(config), path, source_digest, Dict{String,HookCatalog}(),
        Dict{String,HookInvocation}(), Dict{String,Any}[], Dict{String,HookJob}(), ProcessManager(;max_handles=8),
        credential_lookup, ReentrantLock(), ReentrantLock())
end
