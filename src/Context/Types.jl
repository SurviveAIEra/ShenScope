Base.@kwdef struct ContextConfig
    auto_compact::Bool = true
    max_request_bytes::Int = 256 * 1024
    safety_tokens::Int = 1024
    recent_messages::Int = 12
    tool_preview_bytes::Int = 4096
    checkpoint_bytes::Int = 16 * 1024
    max_sources::Int = 128
    source_bytes::Int = 32 * 1024
    instructions_bytes::Int = 256 * 1024
    max_paths::Int = 64
    recovery_attempts::Int = 2
    instruction_names::Vector{String} = ["AGENTS.md", "SHENSCOPE.md"]
    user_files::Vector{String} = String[]
    paths::Vector{String} = String[]
end

struct InstructionSource
    path::String
    scope::Symbol
    directory::String
    sha256::String
    text::String
end

struct ContextGroup
    first::Int
    last::Int
    complete::Bool
    call_ids::Vector{String}
end

struct ContextMeasure
    message_bytes::Int
    tools_bytes::Int
    options_bytes::Int
    envelope_bytes::Int
    wire_bytes::Int
    estimated_tokens::Int
    max_output::Int
    context_window::Int
    input_limit::Int
    byte_limit::Int
end

struct ContextCheckpoint
    id::String
    session_id::String
    root::String
    covered::Int
    prefix_sha256::String
    text::String
    text_sha256::String
    method::Symbol
    sources::Vector{Dict{String,Any}}
    created_at::String
    model::Union{Nothing,Dict{String,Any}}
end

struct ContextProjection
    messages::Vector{Message}
    measure::ContextMeasure
    checkpoint::Union{Nothing,ContextCheckpoint}
    pruned::Vector{Dict{String,Any}}
    instructions::Vector{InstructionSource}
    original_messages::Int
end

mutable struct ContextJob
    id::String
    action::String
    context::RuntimeContext
    session::Session
    status::Symbol
    result::Any
    error::Union{Nothing,String}
    task::Union{Nothing,Task}
    finished_at::Float64
    result_bytes::Int
end

mutable struct ContextManager
    config::ContextConfig
    sessions::Dict{Tuple{String,String},Session}
    latest::Dict{Tuple{String,String},Dict{String,Any}}
    jobs::Dict{String,ContextJob}
    mutex::ReentrantLock
end
ContextManager(config=Dict()) = ContextManager(context_config(config),
    Dict{Tuple{String,String},Session}(), Dict{Tuple{String,String},Dict{String,Any}}(),
    Dict{String,ContextJob}(), ReentrantLock())

const CONTEXT_MAX_SESSIONS = 256
const CONTEXT_MAX_JOBS = 64
const CONTEXT_MAX_ACTIVE_JOBS = 8
const CONTEXT_MAX_JOB_BYTES = 4 * 1024 * 1024
const CONTEXT_MAX_RETAINED_BYTES = 16 * 1024 * 1024
