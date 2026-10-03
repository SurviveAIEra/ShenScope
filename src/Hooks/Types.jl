@enum HookPoint HookSessionStart HookBeforeModel HookAfterModel HookBeforeTool HookAfterTool HookAfterEdit HookAfterTest HookSessionEnd

const HOOK_POINT_NAMES = Dict(HookSessionStart=>"session_start", HookBeforeModel=>"before_model",
    HookAfterModel=>"after_model", HookBeforeTool=>"before_tool", HookAfterTool=>"after_tool",
    HookAfterEdit=>"after_edit", HookAfterTest=>"after_test", HookSessionEnd=>"session_end")
const HOOK_PRE_POINTS = Set([HookSessionStart, HookBeforeModel, HookBeforeTool])

function hook_point(value)
    value isa HookPoint && return value
    value isa AbstractString || throw(ShenScopeError(:hook_config, "Hook lifecycle point must be a string"))
    for (point, name) in HOOK_POINT_NAMES; value == name && return point; end
    throw(ShenScopeError(:hook_config, "Unsupported Hook lifecycle point"))
end

struct HookSpec
    id::String
    name::String
    point::HookPoint
    argv::Vector{String}
    cwd::String
    timeout::Float64
    output_limit::Int
    enabled::Bool
    tools::Vector{String}
    on_failure::Symbol
    allow_context::Bool
    replay_safe::Bool
    environment_env::Dict{String,String}
    scope::Symbol
    source::Union{Nothing,String}
    source_root::String
    source_sha256::String
    declaration_sha256::String
end

struct HookConfig
    enabled::Bool
    project_files::Vector{String}
    user_files::Vector{String}
    entries::Vector{Dict{String,Any}}
    disabled::Vector{String}
    max_hooks::Int
    max_history::Int
end

struct HookCatalog
    root::String
    generation::Int
    config_sha256::String
    specs::Vector{HookSpec}
    sources::Dict{String,String}
    loaded_at::String
end

struct HookOutcome
    invocation_id::String
    hook_id::String
    point::HookPoint
    status::Symbol
    decision::Symbol
    reason::Union{Nothing,String}
    context::String
    error::Union{Nothing,String}
    exit_code::Union{Nothing,Int}
    duration::Float64
    stdout_bytes::Int
    stderr_bytes::Int
    stdin_written::Bool
end

mutable struct HookInvocation
    id::String
    hook_id::String
    context::RuntimeContext
    process::Union{Nothing,ProcessHandle}
end

mutable struct HookJob
    id::String
    action::String
    context::RuntimeContext
    status::Symbol
    result::Any
    error::Union{Nothing,String}
    task::Union{Nothing,Task}
    finished_at::Float64
    opened::Bool
    result_bytes::Int
end

mutable struct HookManager
    config::HookConfig
    config_source::Union{Nothing,String}
    config_source_digest::Union{Nothing,String}
    catalogs::Dict{String,HookCatalog}
    active::Dict{String,HookInvocation}
    history::Vector{Dict{String,Any}}
    jobs::Dict{String,HookJob}
    process::ProcessManager
    credential_lookup::Function
    mutex::ReentrantLock
    discovery_mutex::ReentrantLock
end

mutable struct HookRuntime
    manager::HookManager
    owner::RuntimeContext
    pending::Vector{String}
    context_bytes::Int
    stop_requested::Bool
    effect_observer::Function
    mutex::ReentrantLock
end

const ACTIVE_HOOK_RUNTIME = ScopedValue{Union{Nothing,HookRuntime}}(nothing)
