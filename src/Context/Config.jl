function context_integer(document, key, default, minimum, maximum)
    value = get(document, key, default)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:context_config, "Invalid context limit: " * key))
    Int(value)
end

function context_strings(document, key, default; capacity, maximum=4096)
    values = get(document, key, default)
    values isa AbstractVector && length(values) <= capacity ||
        throw(ShenScopeError(:context_config, "Invalid context list: " * key))
    result = String[]
    for value in values
        value isa AbstractString && !isempty(value) && ncodeunits(value) <= maximum &&
            !occursin('\0', value) || throw(ShenScopeError(:context_config, "Invalid context path or name"))
        push!(result, String(value))
    end
    length(unique(result)) == length(result) || throw(ShenScopeError(:context_config, "Duplicate context entry"))
    result
end

function context_config(config::AbstractDict)
    document = get(config, "context", Dict())
    document isa AbstractDict || throw(ShenScopeError(:context_config, "Context configuration must be a table"))
    allowed = Set(["auto_compact", "max_request_bytes", "safety_tokens", "recent_messages",
        "tool_preview_bytes", "checkpoint_bytes", "max_sources", "source_bytes",
        "instructions_bytes", "max_paths", "recovery_attempts", "instruction_names", "user_files", "paths"])
    all(key -> key in allowed, keys(document)) || throw(ShenScopeError(:context_config, "Unknown context setting"))
    enabled = get(document, "auto_compact", true)
    enabled isa Bool || throw(ShenScopeError(:context_config, "Context auto_compact must be Boolean"))
    names = context_strings(document, "instruction_names", ["AGENTS.md", "SHENSCOPE.md"]; capacity=8, maximum=128)
    all(name -> basename(name) == name && name ∉ (".", "..") && !occursin('/', name) && !occursin('\\', name), names) ||
        throw(ShenScopeError(:context_config, "Instruction names must be plain filenames"))
    user_files = context_strings(document, "user_files", String[]; capacity=8)
    all(isabspath, user_files) || throw(ShenScopeError(:context_config, "User instruction files must be absolute paths"))
    ContextConfig(; auto_compact=enabled,
        max_request_bytes=context_integer(document, "max_request_bytes", 256 * 1024, 2048, 4 * 1024 * 1024),
        safety_tokens=context_integer(document, "safety_tokens", 1024, 0, 128_000),
        recent_messages=context_integer(document, "recent_messages", 12, 1, 256),
        tool_preview_bytes=context_integer(document, "tool_preview_bytes", 4096, 256, 64 * 1024),
        checkpoint_bytes=context_integer(document, "checkpoint_bytes", 16 * 1024, 512, 128 * 1024),
        max_sources=context_integer(document, "max_sources", 128, 1, 512),
        source_bytes=context_integer(document, "source_bytes", 32 * 1024, 256, 1024 * 1024),
        instructions_bytes=context_integer(document, "instructions_bytes", 256 * 1024, 512, 2 * 1024 * 1024),
        max_paths=context_integer(document, "max_paths", 64, 1, 128),
        recovery_attempts=context_integer(document, "recovery_attempts", 2, 0, 4),
        instruction_names=names, user_files,
        paths=context_strings(document, "paths", String[]; capacity=128))
end

function validate_context_config(config::ContextConfig)
    document = Dict{String,Any}(String(name) => getfield(config, name) for name in fieldnames(ContextConfig))
    context_config(Dict("context" => document))
end
