const RUNTIME_EVIDENCE_SCHEMA="shenscope.runtime-evidence/1"
const RUNTIME_EVIDENCE_KINDS=("all","method","statement","allocation","sampling")
const RUNTIME_EVIDENCE_NOTES=["Source joins are declaration candidates, not runtime binding or semantic-equivalence proofs.",
    "Compiler statements describe inference; allocation stack samples describe a separate fixture/helper execution.",
    "One allocation can appear in several retained frames; observation rows must not be summed as allocation totals.",
    "Only selected installed Core files are parsed; no user project, macro expansion or package loading occurs.",
    "Periodic backtrace occurrences are inclusive retained samples, not exclusive CPU time or additive utilization."]

struct RuntimeEvidenceLimits
    files::Int
    declarations::Int
    observations::Int
    candidates::Int
    read_bytes::Int
    retained_bytes::Int
    join_operations::Int
    function RuntimeEvidenceLimits(;files=32,declarations=4096,observations=16_384,candidates=16,
            read_bytes=8*1024^2,retained_bytes=8*1024^2,join_operations=2_000_000)
        values=(files,declarations,observations,candidates,read_bytes,retained_bytes,join_operations)
        all(value->value isa Integer && !(value isa Bool),values) && 1<=files<=64 &&
            1<=declarations<=8192 && 1<=observations<=40_000 && 1<=candidates<=32 &&
            1024<=read_bytes<=16*1024^2 && 1024<=retained_bytes<=16*1024^2 &&
            1<=join_operations<=4_000_000 || throw(ShenScopeError(:diagnostics,"Runtime evidence limits exceed supported bounds"))
        new(Int.(values)...)
    end
end

struct RuntimeEvidenceDeclaration
    key::String
    provider::String
    symbol::CodeSymbol
    sha256::String
end

struct RuntimeEvidenceIntervals
    declarations::Vector{RuntimeEvidenceDeclaration}
    starts::Vector{Int}
    prefix_ends::Vector{Int}
end

struct RuntimeEvidenceSnapshot
    source::RuntimeSourceSnapshot
    target::String
    report_stamps::Vector{Dict{String,Any}}
    provider_stamps::Vector{Dict{String,Any}}
    rows::Vector{Dict{String,Any}}
    declarations::Vector{RuntimeEvidenceDeclaration}
    summary::Dict{String,Any}
    profile_summary::Union{Nothing,Dict{String,Any}}
    sampling_summary::Union{Nothing,Dict{String,Any}}
    fingerprint::String
end

mutable struct RuntimeEvidenceWork
    limits::RuntimeEvidenceLimits
    operations::Int
    context::RuntimeContext
end

function runtime_evidence_tick!(work::RuntimeEvidenceWork;operations=1)
    work.operations+=operations
    work.operations<=work.limits.join_operations || throw(ShenScopeError(:capacity,"Runtime evidence join work exceeds capacity"))
    if work.operations%128==0
        compiler_source_checkpoint(work.context,runtime_core_root());yield()
    end
end

function runtime_evidence_declaration_view(value::RuntimeEvidenceDeclaration)
    symbol=value.symbol
    Dict("key"=>value.key,"provider"=>value.provider,"symbol_id"=>symbol.id.value,"kind"=>String(symbol.kind),
        "name"=>cliptext(symbol.name,256),"qualified_name"=>cliptext(symbol.qualified_name,512),
        "location"=>range_dict(symbol.location),"source_sha256"=>value.sha256,
        "signature"=>cliptext(string(get(symbol.metadata,"signature","")),512),
        "provider_claims_semantic"=>get(symbol.metadata,"semantic",false),"runtime_binding_confirmed"=>false)
end
