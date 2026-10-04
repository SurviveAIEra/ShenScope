struct MigrationAnalyzer <: AbstractAnalyzer end
analyzer_name(::MigrationAnalyzer) = "migration"
requirements(::MigrationAnalyzer) = [:definitions, :calls]

struct MigrationOptions
    change_kind::Symbol
    order::Symbol
    max_files::Int
    max_symbols::Int
    max_relations::Int
    max_depth::Int
    step_limit::Int
    minimum_confidence::Float64
    function MigrationOptions(;change_kind=:signature, order=:dependency_first, max_files=256,
            max_symbols=5000, max_relations=20000, max_depth=8, step_limit=100, minimum_confidence=0.0)
        change_kind in (:signature, :rename, :remove, :move, :behavior) ||
            throw(ShenScopeError(:arguments, "Unknown migration change kind"))
        order in (:dependency_first, :callers_first) || throw(ShenScopeError(:arguments, "Unknown migration ordering"))
        for (name, value, minimum, maximum) in (("files", max_files, 1, 512), ("symbols", max_symbols, 1, 20000),
                ("relations", max_relations, 1, 100000), ("depth", max_depth, 0, 32), ("steps", step_limit, 1, 1000))
            value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
                throw(ShenScopeError(:arguments, "Invalid migration " * name * " limit"))
        end
        minimum_confidence isa Real && !(minimum_confidence isa Bool) && isfinite(minimum_confidence) &&
            0 <= minimum_confidence <= 1 || throw(ShenScopeError(:arguments, "Invalid migration evidence confidence"))
        new(change_kind, order, Int(max_files), Int(max_symbols), Int(max_relations), Int(max_depth),
            Int(step_limit), Float64(minimum_confidence))
    end
end

function migration_options(request::AbstractDict)
    kind = get(request, "change_kind", "signature")
    order = get(request, "order", "dependency_first")
    kind isa AbstractString && order isa AbstractString || throw(ShenScopeError(:arguments, "Migration intent and ordering must be strings"))
    MigrationOptions(;change_kind=Symbol(kind), order=Symbol(order), max_files=get(request, "max_files", 256),
        max_symbols=get(request, "max_symbols", 5000), max_relations=get(request, "max_relations", 20000),
        max_depth=get(request, "max_depth", 8), step_limit=get(request, "limit", 100),
        minimum_confidence=get(request, "minimum_confidence", 0.0))
end

struct MigrationFile
    path::String
    sha256::String
    symbol_ids::Vector{String}
    test_ids::Vector{String}
end

mutable struct MigrationDependency
    source::String
    target::String
    relation_ids::Vector{String}
    kinds::Set{String}
    minimum_confidence::Float64
end

struct MigrationGraph
    snapshot::AnalyzerGraphSnapshot
    files::Dict{String,MigrationFile}
    seeds::Set{String}
    forward::Dict{String,Set{String}}
    reverse::Dict{String,Set{String}}
    dependencies::Dict{Tuple{String,String},MigrationDependency}
    excluded_confidence::Int
    ignored_relations::Int
end

struct MigrationBatch
    id::String
    files::Vector{String}
    dependencies::Vector{String}
    cycle::Bool
    layer::Int
end

struct MigrationPlan
    id::String
    graph::MigrationGraph
    options::MigrationOptions
    batches::Vector{MigrationBatch}
    cycle_count::Int
end
