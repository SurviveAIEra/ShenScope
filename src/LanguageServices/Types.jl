const LANGUAGE_SERVICE_SCHEMA = "shenscope.language-service/1"
const LSP_QUERY_METHODS = Dict(
    "definitions" => "textDocument/definition", "references" => "textDocument/references",
    "hover" => "textDocument/hover", "implementations" => "textDocument/implementation",
    "type_definitions" => "textDocument/typeDefinition", "document_symbols" => "textDocument/documentSymbol",
    "workspace_symbols" => "workspace/symbol", "format" => "textDocument/formatting",
    "rename" => "textDocument/rename", "code_actions" => "textDocument/codeAction",
    "completions" => "textDocument/completion", "signature_help" => "textDocument/signatureHelp")

Base.@kwdef struct LanguageServiceLimits
    maximum_servers::Int = 8
    maximum_documents::Int = 64
    maximum_document_bytes::Int = 512*1024
    maximum_document_total_bytes::Int = 16*1024^2
    maximum_message_bytes::Int = 4*1024^2
    maximum_pending::Int = 16
    maximum_diagnostics::Int = 256
    maximum_result_items::Int = 1000
    maximum_inbound_requests::Int = 16
    maximum_progress_tokens::Int = 32
end

function validate_language_limits(limits::LanguageServiceLimits)
    1 <= limits.maximum_servers <= 32 && 1 <= limits.maximum_documents <= 256 &&
        4096 <= limits.maximum_document_bytes <= 2*1024^2 &&
        limits.maximum_document_bytes <= limits.maximum_document_total_bytes <= 32*1024^2 &&
        4096 <= limits.maximum_message_bytes <= 8*1024^2 &&
        1 <= limits.maximum_pending <= 64 && 1 <= limits.maximum_diagnostics <= 1024 &&
        1 <= limits.maximum_result_items <= 4096 &&
        1 <= limits.maximum_inbound_requests <= 64 && 1 <= limits.maximum_progress_tokens <= 128 ||
        throw(ShenScopeError(:language_config, "Invalid language-service capacities"))
    limits
end

struct LanguageServerSpec
    name::String
    argv::Vector{String}
    cwd::String
    languages::Vector{String}
    initialization_options::Dict{String,Any}
    settings::Dict{String,Any}
    timeout::Float64
    fingerprint::String
end

struct LanguageResponseError
    code::Int
end

mutable struct LanguagePendingRequest
    id::String
    method::String
    generation::Int
    context::RuntimeContext
    result::Channel{Any}
    started_at::Float64
end

mutable struct LanguageDocument
    snapshot::WorkspaceSourceSnapshot
    language::String
    version::Int
    generation::Int
    synchronized_at::Float64
    diagnostic_items::Vector{ProjectProblem}
    diagnostic_version::Union{Nothing,Int}
    diagnostic_received::Bool
    diagnostic_omitted::Int
    diagnostic_sequence::Int
end

mutable struct LanguageClient
    spec::LanguageServerSpec
    context::RuntimeContext
    limits::LanguageServiceLimits
    generation::Int
    state::Symbol
    transport::Union{Nothing,MCPStdioTransport}
    pending::Dict{String,LanguagePendingRequest}
    documents::Dict{String,LanguageDocument}
    capabilities::Dict{String,Any}
    inbound_requests::Set{String}
    progress::Dict{String,Dict{String,Any}}
    sequence::Int
    diagnostic_sequence::Int
    last_error::Union{Nothing,Symbol}
    lifecycle_mutex::ReentrantLock
    document_mutex::ReentrantLock
    mutex::ReentrantLock
    monitor::Union{Nothing,Task}
end

function LanguageClient(spec::LanguageServerSpec, ctx::RuntimeContext; limits=LanguageServiceLimits())
    validate_language_limits(limits)
    LanguageClient(spec, child_context(ctx), limits, 1, :created, nothing, Dict(), Dict(), Dict(),
        Set(), Dict(), 0, 0, nothing, ReentrantLock(), ReentrantLock(), ReentrantLock(), nothing)
end

mutable struct LanguageServiceManager
    clients::Dict{String,LanguageClient}
    limits::LanguageServiceLimits
    mutex::ReentrantLock
    closed::Bool
end

function LanguageServiceManager(; limits=LanguageServiceLimits())
    validate_language_limits(limits)
    LanguageServiceManager(Dict(), limits, ReentrantLock(), false)
end

function language_text(value, label, maximum; empty=false)
    try
        problem_text(value, label, maximum; empty)
    catch cause
        cause isa ShenScopeError || rethrow()
        throw(ShenScopeError(:language_config, "Invalid " * label))
    end
end

function language_fields(value, required, optional, label)
    value isa AbstractDict && all(key -> key isa String, keys(value)) &&
        all(key -> haskey(value, key), required) && all(key -> key in required || key in optional, keys(value)) ||
        throw(ShenScopeError(:language_protocol, "Invalid " * label * " fields"))
    value
end

function language_integer(value, label, minimum, maximum)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:language_protocol, "Invalid " * label))
    Int(value)
end
