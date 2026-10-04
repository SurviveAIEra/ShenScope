struct GitHistoryLimits
    commits::Int
    files_per_commit::Int
    total_changes::Int
    output_bytes::Int
    timeout_seconds::Float64
    bulk_threshold::Int
    function GitHistoryLimits(;commits=128, files_per_commit=512, total_changes=32768,
            output_bytes=4 * 1024 * 1024, timeout_seconds=120.0, bulk_threshold=32)
        for (name, value, minimum, maximum) in (("commits", commits, 1, 512),
                ("files per commit", files_per_commit, 1, 2048),
                ("total changes", total_changes, 1, 65536),
                ("output bytes", output_bytes, 1024, 4 * 1024 * 1024),
                ("bulk threshold", bulk_threshold, 2, 2048))
            value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
                throw(ShenScopeError(:arguments, "Invalid Git history " * name * " limit"))
        end
        timeout_seconds isa Real && !(timeout_seconds isa Bool) && isfinite(timeout_seconds) &&
            0.05 <= timeout_seconds <= 600 || throw(ShenScopeError(:arguments, "Invalid Git history timeout"))
        bulk_threshold <= files_per_commit || throw(ShenScopeError(:arguments, "Bulk threshold exceeds retained file capacity"))
        new(Int(commits), Int(files_per_commit), Int(total_changes), Int(output_bytes),
            Float64(timeout_seconds), Int(bulk_threshold))
    end
end

struct GitHistoryChange
    path::String
    added::Union{Nothing,Int}
    removed::Union{Nothing,Int}
end

struct GitHistoryCommit
    id::String
    parents::Tuple{Vararg{String}}
    committed_at::Int
    changes::Vector{GitHistoryChange}
    omitted_changes::Int
    ordinal::Int
end

struct GitHistorySnapshot
    root::String
    head::String
    object_format::String
    git_version::String
    shallow::Bool
    commits::Vector{GitHistoryCommit}
    limit_reached::Bool
    raw_sha256::String
    output_bytes::Int
    limits::GitHistoryLimits
end

struct GitHistoryRepository
    root::String
    git_directory::String
    executable::String
    declaration_hash::String
end

const GIT_HISTORY_PHASES = (:version, :head, :shallow, :history, :verify_head)
git_object_id(value::AbstractString) = occursin(r"^(?:[a-f0-9]{40}|[a-f0-9]{64})$", value)

function git_history_limits(request::AbstractDict)
    GitHistoryLimits(;commits=get(request, "history_limit", 128),
        bulk_threshold=get(request, "bulk_threshold", 32),
        timeout_seconds=get(request, "history_timeout", 120.0))
end
