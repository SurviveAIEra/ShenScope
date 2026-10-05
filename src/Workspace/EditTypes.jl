const WORKSPACE_EDIT_SCHEMA = "shenscope.workspace-edit/1"

Base.@kwdef struct WorkspaceEditLimits
    maximum_files::Int = 64
    maximum_edits::Int = 2048
    maximum_file_bytes::Int = 4*1024^2
    maximum_total_bytes::Int = 32*1024^2
    maximum_replacement_bytes::Int = 8*1024^2
    maximum_plans::Int = 16
    maximum_retained_bytes::Int = 64*1024^2
    maximum_preview_bytes::Int = 128*1024
end

function validate_workspace_edit_limits(limits::WorkspaceEditLimits)
    1 <= limits.maximum_files <= 128 && 1 <= limits.maximum_edits <= 8192 &&
        1024 <= limits.maximum_file_bytes <= 8*1024^2 &&
        limits.maximum_file_bytes <= limits.maximum_total_bytes <= 64*1024^2 &&
        1024 <= limits.maximum_replacement_bytes <= 32*1024^2 &&
        1 <= limits.maximum_plans <= 64 &&
        limits.maximum_total_bytes <= limits.maximum_retained_bytes <= 128*1024^2 &&
        1024 <= limits.maximum_preview_bytes <= 512*1024 ||
        throw(ShenScopeError(:workspace_edit, "Invalid workspace edit capacities"))
    limits
end

struct WorkspaceTextEdit
    location::SourceRange
    first_byte::Int
    after_byte::Int
    new_text::String
end

struct WorkspaceFileEdit
    source::WorkspaceSourceSnapshot
    edits::Vector{WorkspaceTextEdit}
    after_text::String
    after_sha256::String
    mode::UInt
end

mutable struct WorkspaceEditPlan
    id::String
    scope::Tuple{String,String,String}
    title::String
    origin::String
    files::Vector{WorkspaceFileEdit}
    created_at::String
    sha256::String
    bytes::Int
    status::Symbol
    receipt::Union{Nothing,Dict{String,Any}}
    verification::Union{Nothing,Dict{String,Any}}
    mutex::ReentrantLock
end

mutable struct WorkspaceEditManager
    plans::Dict{String,WorkspaceEditPlan}
    order::Vector{String}
    retained_bytes::Int
    limits::WorkspaceEditLimits
    mutex::ReentrantLock
    closed::Bool
end

function WorkspaceEditManager(; limits=WorkspaceEditLimits())
    validate_workspace_edit_limits(limits)
    WorkspaceEditManager(Dict(), String[], 0, limits, ReentrantLock(), false)
end

function workspace_edit_fields(value, required, optional, label)
    value isa AbstractDict && all(key -> key isa String, keys(value)) &&
        all(key -> haskey(value, key), required) && all(key -> key in required || key in optional, keys(value)) ||
        throw(ShenScopeError(:workspace_edit, "Invalid " * label * " fields"))
    value
end

function workspace_edit_text(value, label, maximum; empty=false)
    value isa AbstractString && isvalid(value) && ncodeunits(value) <= maximum &&
        !occursin('\0', value) && (empty || !isempty(strip(value))) ||
        throw(ShenScopeError(:workspace_edit, "Invalid " * label))
    String(value)
end

function workspace_edit_hash(value, label)
    value isa String && occursin(r"^[a-f0-9]{64}$", value) ||
        throw(ShenScopeError(:workspace_edit, "Invalid " * label))
    value
end
