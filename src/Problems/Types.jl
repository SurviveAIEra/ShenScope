const PROBLEM_SCHEMA = "shenscope.project-problems/1"
const PROBLEM_SEVERITIES = ("error", "warning", "information", "hint")

Base.@kwdef struct ProblemLimits
    maximum_files::Int = 512
    maximum_items::Int = 4096
    maximum_per_file::Int = 256
    maximum_message_bytes::Int = 16*1024
    maximum_source_bytes::Int = 8*1024^2
    maximum_read_bytes::Int = 32*1024^2
    maximum_result_bytes::Int = 3*1024^2
    maximum_snapshots::Int = 32
    maximum_retained_bytes::Int = 16*1024^2
end

function validate_problem_limits(limits::ProblemLimits)
    all(name -> getfield(limits, name) isa Int, fieldnames(ProblemLimits)) ||
        throw(ShenScopeError(:problems, "Invalid problem capacities"))
    1 <= limits.maximum_files <= 4096 && 1 <= limits.maximum_items <= 16384 &&
        1 <= limits.maximum_per_file <= limits.maximum_items &&
        128 <= limits.maximum_message_bytes <= 64*1024 &&
        1024 <= limits.maximum_source_bytes <= 8*1024^2 &&
        limits.maximum_source_bytes <= limits.maximum_read_bytes <= 128*1024^2 &&
        4096 <= limits.maximum_result_bytes <= 4*1024^2 &&
        1 <= limits.maximum_snapshots <= 128 &&
        limits.maximum_result_bytes <= limits.maximum_retained_bytes <= 64*1024^2 ||
        throw(ShenScopeError(:problems, "Invalid problem capacities"))
    limits
end

struct ProjectProblem
    id::String
    path::String
    source_sha256::String
    severity::String
    message::String
    source::String
    code::Union{Nothing,String,Int}
    location::Union{Nothing,SourceRange}
    tags::Vector{String}
    semantic::Bool
    metadata::Dict{String,Any}
end

struct ProblemFileReport
    path::String
    sha256::String
    items::Vector{ProjectProblem}
    reported_items::Int
    omitted_items::Int
    status::String
    version::Union{Nothing,Int}
    unicode_line_separators::Bool
end

struct ProblemSnapshot
    id::String
    scope::Tuple{String,String,String}
    provider::String
    revision::Int
    configuration::Vector{Dict{String,Any}}
    files::Vector{ProblemFileReport}
    coverage::Dict{String,Any}
    created_at::String
    sha256::String
    bytes::Int
end

mutable struct ProblemManager
    snapshots::Dict{String,ProblemSnapshot}
    order::Vector{String}
    retained_bytes::Int
    limits::ProblemLimits
    mutex::ReentrantLock
    closed::Bool
end

function ProblemManager(; limits=ProblemLimits())
    validate_problem_limits(limits)
    ProblemManager(Dict(), String[], 0, limits, ReentrantLock(), false)
end

problem_scope(ctx::RuntimeContext) = operation_scope(ctx)

function problem_text(value, label, maximum; empty=false)
    value isa AbstractString && isvalid(value) && ncodeunits(value) <= maximum &&
        !occursin('\0', value) && (empty || !isempty(strip(value))) ||
        throw(ShenScopeError(:problems, "Invalid " * label))
    String(value)
end

function problem_integer(value, label, minimum, maximum)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:problems, "Invalid " * label))
    Int(value)
end

function problem_fields(value, required, optional, label)
    value isa AbstractDict && all(key -> key isa String, keys(value)) &&
        all(key -> haskey(value, key), required) &&
        all(key -> key in required || key in optional, keys(value)) ||
        throw(ShenScopeError(:problems, "Invalid " * label * " fields"))
    value
end

function problem_hash(value, label="problem source hash")
    value isa String && occursin(r"^[0-9a-f]{64}$", value) ||
        throw(ShenScopeError(:problems, "Invalid " * label))
    value
end
