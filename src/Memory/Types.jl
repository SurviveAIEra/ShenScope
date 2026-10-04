const MEMORY_DEFAULT_NAMESPACE = "default"
const MAX_MEMORY_NAMESPACES = 32
const MAX_MEMORY_SNAPSHOT_BYTES = 8*1024^2
const MAX_MEMORY_QUERY_BYTES = 4096
const MAX_MEMORY_QUERY_TERMS = 64
const MAX_MEMORY_INDEX_POSTINGS = 200000
const MAX_MEMORY_INDEX_TOKENS = 262144
const MAX_MEMORY_PREVIEW_BYTES = 3*1024^2

struct MemoryStore
    versions::VersionedStore
    scope::Symbol
    owner::String
    namespace::String
    workspace_sha256::Union{Nothing,String}
end
MemoryStore(versions::VersionedStore,scope::Symbol,owner::String) =
    MemoryStore(versions,scope,owner,MEMORY_DEFAULT_NAMESPACE,scope==:workspace ? owner : nothing)
MemoryStore(versions::VersionedStore,scope::Symbol,owner::String,namespace::String) =
    MemoryStore(versions,scope,owner,namespace,scope==:workspace ? owner : nothing)

struct MemoryDocument
    key::String
    version::Int
    record_sha256::String
    content_sha256::Union{Nothing,String}
    value::Dict{String,Any}
    created::String
    updated::String
    deleted::Bool
end

struct MemorySnapshot
    store::MemoryStore
    id::String
    scope_id::String
    documents::Vector{MemoryDocument}
    captured_at::Float64
    input_bytes::Int
    total_records::Int
    omitted_records::Int
end

struct MemoryToken
    value::String
    start_byte::Int
    end_byte::Int
end

struct MemoryPosting
    document::Int
    title_count::Int
    content_count::Int
    tags_count::Int
    title_span::Union{Nothing,Tuple{Int,Int}}
    content_span::Union{Nothing,Tuple{Int,Int}}
    tags_span::Union{Nothing,Tuple{Int,Int}}
end

struct MemoryLexicalIndex
    snapshot::MemorySnapshot
    postings::Dict{String,Vector{MemoryPosting}}
    lengths::Vector{NTuple{3,Int}}
    averages::NTuple{3,Float64}
    token_count::Int
    posting_count::Int
    omitted_tokens::Int
    partial_documents::Set{Int}
end

struct MemoryQuery
    text::String
    optional::Tuple{Vararg{String}}
    required::Tuple{Vararg{String}}
    excluded::Tuple{Vararg{String}}
    phrases::Tuple{Vararg{String}}
    excluded_phrases::Tuple{Vararg{String}}
end

struct MemoryFilters
    tags_all::Tuple{Vararg{String}}
    tags_any::Tuple{Vararg{String}}
    sources::Tuple{Vararg{String}}
    include_expired::Bool
    include_deleted::Bool
    updated_after::Union{Nothing,String}
    updated_before::Union{Nothing,String}
end

struct MemoryRetrievalOptions
    filters::MemoryFilters
    match::Symbol
    sort::Symbol
    offset::Int
    limit::Int
    snippet_chars::Int
    expected_snapshot::Union{Nothing,String}
    cursor::Union{Nothing,String}
end

mutable struct MemoryManager
    operations::OperationManager
    indexes::Dict{String,MemoryLexicalIndex}
    touched::Dict{String,UInt64}
    mutex::ReentrantLock
    max_indexes::Int
    max_retained_input_bytes::Int
    closed::Bool
end

function MemoryManager(;max_indexes=4,max_retained_input_bytes=16*1024^2)
    max_indexes isa Integer && !(max_indexes isa Bool) && 1<=max_indexes<=32 &&
        max_retained_input_bytes isa Integer && !(max_retained_input_bytes isa Bool) &&
        MAX_MEMORY_SNAPSHOT_BYTES<=max_retained_input_bytes<=64*1024^2 ||
        throw(ArgumentError("Invalid memory index capacities"))
    MemoryManager(OperationManager(;event_prefix="memory"),Dict(),Dict(),ReentrantLock(),
        Int(max_indexes),Int(max_retained_input_bytes),false)
end
