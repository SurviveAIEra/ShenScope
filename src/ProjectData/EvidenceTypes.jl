const PROJECT_EVIDENCE_ACTIONS = Set(["evidence_compare", "evidence_search", "evidence_impact", "evidence_tests"])
const PROJECT_EVIDENCE_MAX_BYTES = 8 * 1024 * 1024
const PROJECT_EVIDENCE_MAX_READ_BYTES = 32 * 1024 * 1024
const PROJECT_EVIDENCE_MAX_FILES = 4000

struct EvidenceLimits
    sources::Int
    symbols::Int
    relations::Int
    bytes::Int
    depth::Int
    confidence::Float64
    bridges::Bool
end

struct EvidenceSourceStamp
    backend::String
    revision::Int
    capabilities::BackendCapabilities
    files::Dict{String,String}
    selection_sha256::String
end

struct EvidenceSymbol
    key::String
    backend::String
    revision::Int
    symbol::CodeSymbol
    source_sha256::String
end

struct EvidenceRelation
    key::String
    backend::String
    revision::Int
    relation::Relation
    src::String
    dst::String
    source_sha256::String
end

struct EvidenceAnchor
    id::String
    members::Vector{String}
    path::String
    source_sha256::String
    location::SourceRange
    qualified_name::String
    eligible_bridge::Bool
end

struct ProjectEvidenceSnapshot
    root::String
    sources::Vector{EvidenceSourceStamp}
    symbols::Dict{String,EvidenceSymbol}
    relations::Dict{String,EvidenceRelation}
    forward::Dict{String,Vector{String}}
    reverse::Dict{String,Vector{String}}
    anchors::Dict{String,EvidenceAnchor}
    member_anchors::Dict{String,String}
    files::Dict{String,String}
    fingerprint::String
    bytes::Int
    limits::EvidenceLimits
end

evidence_symbol_key(backend::AbstractString, id::SymbolId) = digest(canonical(["symbol",backend,id.value]))[1:32]
evidence_relation_key(backend::AbstractString, id::AbstractString) = digest(canonical(["relation",backend,id]))

function evidence_symbol_dict(value::EvidenceSymbol)
    Dict("key"=>value.key,"backend"=>value.backend,"source_revision"=>value.revision,
        "indexed_source_sha256"=>value.source_sha256,"symbol"=>symbol_dict(value.symbol),
        "provider_claims_semantic"=>get(value.symbol.metadata,"semantic",false))
end

function evidence_relation_dict(value::EvidenceRelation)
    Dict("key"=>value.key,"backend"=>value.backend,"source_revision"=>value.revision,
        "indexed_source_sha256"=>value.source_sha256,"src"=>value.src,"dst"=>value.dst,
        "relation"=>relation_dict(value.relation))
end

function evidence_source_dict(stamp::EvidenceSourceStamp)
    Dict("backend"=>stamp.backend,"revision"=>stamp.revision,"files"=>length(stamp.files),
        "selection_sha256"=>stamp.selection_sha256,"capabilities"=>capability_dict(stamp.capabilities))
end

function evidence_anchor_dict(anchor::EvidenceAnchor)
    Dict("id"=>anchor.id,"members"=>copy(anchor.members),"file"=>anchor.path,
        "indexed_source_sha256"=>anchor.source_sha256,"location"=>range_dict(anchor.location),
        "qualified_name"=>anchor.qualified_name,"eligible_bridge"=>anchor.eligible_bridge,
        "evidence_kind"=>"identical_source_declaration_anchor","runtime_equivalence_confirmed"=>false)
end
