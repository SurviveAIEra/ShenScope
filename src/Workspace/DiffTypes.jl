Base.@kwdef struct WorkspaceDiffOptions
    maximum_input_bytes::Int = 4*1024^2
    maximum_lines::Int = 20_000
    maximum_edit_distance::Int = 512
    maximum_trace_cells::Int = 2_000_000
    maximum_output_bytes::Int = 128*1024
    maximum_hunks::Int = 64
    context_lines::Int = 3
end

function validate_workspace_diff_options(options::WorkspaceDiffOptions)
    1024 <= options.maximum_input_bytes <= 8*1024^2 && 1 <= options.maximum_lines <= 100_000 &&
        1 <= options.maximum_edit_distance <= 2048 && 1024 <= options.maximum_trace_cells <= 8_000_000 &&
        128 <= options.maximum_output_bytes <= 512*1024 && 1 <= options.maximum_hunks <= 256 &&
        0 <= options.context_lines <= 20 || throw(ShenScopeError(:workspace_diff,"Invalid source diff capacities"))
    options
end

struct WorkspaceDiffLine
    operation::Symbol
    before_line::Union{Nothing,Int}
    after_line::Union{Nothing,Int}
    text::String
end

struct WorkspaceDiffHunk
    before_start::Int
    before_count::Int
    after_start::Int
    after_count::Int
    lines::Vector{WorkspaceDiffLine}
end

struct WorkspaceSourceDiff
    path::String
    before_sha256::String
    after_sha256::String
    before_final_newline::Bool
    after_final_newline::Bool
    hunks::Vector{WorkspaceDiffHunk}
    added_lines::Int
    removed_lines::Int
    omitted_hunks::Int
end

function workspace_diff_lines(text::String, options::WorkspaceDiffOptions)
    isvalid(text) && !occursin('\0',text) && ncodeunits(text) <= options.maximum_input_bytes ||
        throw(ShenScopeError(:workspace_diff,"Source diff input exceeds text capacity"))
    isempty(text) && return String[]
    lines=String.(split(text,'\n';keepempty=true))
    endswith(text,'\n') && pop!(lines)
    length(lines) <= options.maximum_lines || throw(ShenScopeError(:workspace_diff,"Source diff line count exceeds capacity"))
    lines
end

function workspace_diff_checkpoint(ctx, ordinal)
    ctx === nothing && return
    ordinal % 128 == 0 || return
    workspace_source_checkpoint(ctx)
    yield()
end
