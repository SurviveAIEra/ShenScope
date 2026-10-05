const PROJECT_VALIDATION_SCHEMA = "shenscope.project-validation/1"
const VALIDATION_FAMILIES = ("generic", "gcc", "typescript", "python", "go", "none")

Base.@kwdef struct ValidationLimits
    maximum_files::Int = 64
    maximum_file_bytes::Int = 512*1024
    maximum_source_bytes::Int = 8*1024^2
    maximum_lines::Int = 8192
    maximum_line_bytes::Int = 8192
    maximum_diagnostics::Int = 512
    maximum_reports::Int = 32
    maximum_report_bytes::Int = 2*1024^2
    maximum_retained_bytes::Int = 16*1024^2
end

function validate_validation_limits(limits::ValidationLimits)
    1 <= limits.maximum_files <= 256 && 1024 <= limits.maximum_file_bytes <= 2*1024^2 &&
        limits.maximum_file_bytes <= limits.maximum_source_bytes <= 32*1024^2 &&
        1 <= limits.maximum_lines <= 32768 && 128 <= limits.maximum_line_bytes <= 64*1024 &&
        1 <= limits.maximum_diagnostics <= 4096 && 1 <= limits.maximum_reports <= 128 &&
        4096 <= limits.maximum_report_bytes <= 4*1024^2 &&
        limits.maximum_report_bytes <= limits.maximum_retained_bytes <= 64*1024^2 ||
        throw(ShenScopeError(:validation, "Invalid project validation capacities"))
    limits
end

mutable struct ProjectValidationManager
    reports::Dict{String,Dict{String,Any}}
    order::Vector{String}
    scopes::Dict{String,Tuple{String,String,String}}
    retained_bytes::Int
    limits::ValidationLimits
    testing::ProjectTestManager
    problems::ProblemManager
    mutex::ReentrantLock
    closed::Bool
end

function ProjectValidationManager(testing=ProjectTestManager(), problems=ProblemManager(); limits=ValidationLimits())
    validate_validation_limits(limits)
    ProjectValidationManager(Dict(), String[], Dict(), 0, limits, testing, problems, ReentrantLock(), false)
end

struct ValidationDiagnosticFrame
    path::String
    line::Int
    column::Union{Nothing,Int}
    severity::String
    message::String
    code::Union{Nothing,String}
    stream::String
    output_line::Int
end

function validation_family(value)
    value isa String && value in VALIDATION_FAMILIES ||
        throw(ShenScopeError(:validation, "Unsupported compiler output interpretation"))
    value
end

function validation_column_unit(value)
    value in ("unknown", "utf8_byte", "utf16", "unicode_scalar") ||
        throw(ShenScopeError(:validation, "Unsupported compiler column encoding"))
    String(value)
end
