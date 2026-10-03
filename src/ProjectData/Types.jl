struct SymbolId
    value::String
    function SymbolId(value::AbstractString)
        occursin(r"^[a-f0-9]{32}$",value) || throw(ShenScopeError(:graph,"Invalid symbol ID"))
        new(String(value))
    end
end
Base.:(==)(a::SymbolId,b::SymbolId)=a.value==b.value
Base.hash(id::SymbolId,h::UInt)=hash(id.value,h)
Base.isless(a::SymbolId,b::SymbolId)=isless(a.value,b.value)
symbol_id(parts...)=SymbolId(digest(canonical(collect(parts)))[1:32])

struct SourceRange
    file::String
    start_line::Int
    end_line::Int
    start_column::Int
    end_column::Int
    function SourceRange(file::AbstractString,start_line::Integer,end_line::Integer;start_column=1,end_column=1)
        1<=start_line<=end_line && start_column>=1 && end_column>=1 || throw(ShenScopeError(:graph,"Invalid source range"))
        new(String(file),start_line,end_line,start_column,end_column)
    end
end

struct CodeSymbol
    id::SymbolId
    kind::Symbol
    name::String
    qualified_name::String
    location::SourceRange
    language::Symbol
    metadata::Dict{String,Any}
end

struct Relation
    id::String
    src::SymbolId
    dst::SymbolId
    kind::Symbol
    location::SourceRange
    confidence::Float64
    provenance::String
end
function Relation(src::SymbolId,dst::SymbolId,kind::Symbol,location::SourceRange;confidence=1.0,provenance="syntax")
    isfinite(confidence) && 0<=confidence<=1 || throw(ShenScopeError(:graph,"Invalid relation confidence"))
    id=digest(canonical([src.value,dst.value,String(kind),range_dict(location)]))
    Relation(id,src,dst,kind,location,confidence,String(provenance))
end

struct CallReference
    src::SymbolId
    name::String
    location::SourceRange
    qualified::Bool
end

struct FileFacts
    path::String
    sha256::String
    symbols::Vector{CodeSymbol}
    relations::Vector{Relation}
    references::Vector{CallReference}
    diagnostics::Vector{Dict{String,Any}}
end

Base.@kwdef struct BackendCapabilities
    name::String
    languages::Vector{String}
    syntax::Bool=true
    definitions::Bool=true
    calls::Symbol=:heuristic
    types::Bool=false
    references::Bool=false
    inheritance::Bool=false
    diagnostics::Bool=false
    incremental_parse::Bool=true
    global_relink::Bool=false
end
backend_capabilities(::AbstractProjectDataBackend)=throw(ShenScopeError(:extension,"Backend must implement capabilities"))
extract_files(::AbstractProjectDataBackend,files,ctx)=throw(ShenScopeError(:extension,"Backend must implement extract_files"))
backend_close!(::AbstractProjectDataBackend)=nothing

range_dict(r::SourceRange)=Dict("file"=>r.file,"start_line"=>r.start_line,"end_line"=>r.end_line,
    "start_column"=>r.start_column,"end_column"=>r.end_column,"column_unit"=>"utf8_byte")
range_from(d::AbstractDict)=SourceRange(d["file"],d["start_line"],d["end_line"];
    start_column=get(d,"start_column",1),end_column=get(d,"end_column",1))
symbol_dict(s::CodeSymbol)=Dict("id"=>s.id.value,"kind"=>String(s.kind),"name"=>s.name,
    "qualified_name"=>s.qualified_name,"location"=>range_dict(s.location),"language"=>String(s.language),"metadata"=>s.metadata)
function symbol_from(d::AbstractDict)
    CodeSymbol(SymbolId(d["id"]),Symbol(d["kind"]),d["name"],d["qualified_name"],range_from(d["location"]),
        Symbol(d["language"]),Dict{String,Any}(d["metadata"]))
end
relation_dict(r::Relation)=Dict("id"=>r.id,"src"=>r.src.value,"dst"=>r.dst.value,"kind"=>String(r.kind),
    "location"=>range_dict(r.location),"confidence"=>r.confidence,"provenance"=>r.provenance)
function relation_from(d::AbstractDict)
    r=Relation(SymbolId(d["src"]),SymbolId(d["dst"]),Symbol(d["kind"]),range_from(d["location"]);
        confidence=d["confidence"],provenance=d["provenance"])
    r.id==d["id"] || throw(ShenScopeError(:storage,"Relation identity mismatch"));r
end
function facts_dict(f::FileFacts)
    Dict("path"=>f.path,"sha256"=>f.sha256,"symbols"=>symbol_dict.(f.symbols),"relations"=>relation_dict.(f.relations),
        "references"=>[Dict("src"=>r.src.value,"name"=>r.name,"location"=>range_dict(r.location),"qualified"=>r.qualified) for r in f.references],
        "diagnostics"=>f.diagnostics)
end
function facts_from(d::AbstractDict)
    FileFacts(d["path"],d["sha256"],symbol_from.(d["symbols"]),relation_from.(d["relations"]),
        [CallReference(SymbolId(r["src"]),r["name"],range_from(r["location"]),r["qualified"]) for r in d["references"]],
        Dict{String,Any}.(d["diagnostics"]))
end
capability_dict(c::BackendCapabilities)=Dict(String(field)=>getfield(c,field) isa Symbol ? String(getfield(c,field)) : getfield(c,field) for field in fieldnames(BackendCapabilities))
