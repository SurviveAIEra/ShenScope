const MODEL_CATALOG_FEATURES = Set(["streaming","tools","parallel_tools","vision","reasoning","structured_output","prompt_cache"])
const MODEL_CATALOG_MAX_MODELS = 4096

struct CatalogDiagnostic
    model_id::Union{Nothing,String}
    code::Symbol
    message::String
end
catalog_diagnostic_dict(value::CatalogDiagnostic) = Dict("model_id"=>value.model_id,"code"=>String(value.code),"message"=>value.message)

struct ModelDescriptor
    id::String
    name::String
    source_id::String
    protocol::Symbol
    context_window::Union{Nothing,Int}
    max_input::Union{Nothing,Int}
    max_output::Union{Nothing,Int}
    features::Dict{String,Union{Nothing,Bool}}
    operations::Vector{String}
    provenance::Dict{String,String}
end

function catalog_identifier(value;maximum=512,field="model identifier")
    value isa AbstractString && isvalid(value) && 1 <= ncodeunits(value) <= maximum &&
        strip(value) == value && !any(character -> iscntrl(character),value) ||
        throw(ShenScopeError(:catalog,"Invalid "*field))
    String(value)
end

function catalog_limit(value,field::String)
    value === nothing && return nothing
    value isa Integer && !(value isa Bool) && 1 <= value <= 4_000_000 ||
        throw(ShenScopeError(:catalog,"Invalid "*field))
    Int(value)
end

function model_descriptor(id,name,source_id,protocol;context_window=nothing,max_input=nothing,max_output=nothing,
        features=Dict(),operations=String[],provenance=Dict())
    identifier = catalog_identifier(id)
    title = catalog_identifier(name;maximum=1024,field="model display name")
    occursin(r"^[a-f0-9]{64}$",source_id) || throw(ShenScopeError(:catalog,"Invalid catalog source identity"))
    protocol in (:openai_chat,:openai_responses,:anthropic,:gemini,:ollama) || throw(ShenScopeError(:catalog,"Invalid catalog protocol"))
    context = catalog_limit(context_window,"context capacity");input = catalog_limit(max_input,"input capacity");output = catalog_limit(max_output,"output capacity")
    context !== nothing && output !== nothing && output >= context && throw(ShenScopeError(:catalog,"Output capacity must be smaller than context capacity"))
    all(key -> key in MODEL_CATALOG_FEATURES,keys(features)) || throw(ShenScopeError(:catalog,"Unknown model feature"))
    all(value -> value === nothing || value isa Bool,values(features)) || throw(ShenScopeError(:catalog,"Model feature must be Boolean or unknown"))
    known = Dict{String,Union{Nothing,Bool}}(key=>get(features,key,nothing) for key in MODEL_CATALOG_FEATURES)
    all(operation -> operation in ("chat","count_tokens","embed","image"),operations) || throw(ShenScopeError(:catalog,"Unknown model operation"))
    evidence = Dict{String,String}()
    for (field,value) in provenance
        field in union(MODEL_CATALOG_FEATURES,Set(["context_window","max_input","max_output","name","operations"])) &&
            value in ("configuration","provider_api") || throw(ShenScopeError(:catalog,"Invalid model field provenance"))
        evidence[String(field)] = String(value)
    end
    ModelDescriptor(identifier,title,String(source_id),protocol,context,input,output,known,sort!(unique(String.(operations))),evidence)
end

function model_descriptor_dict(model::ModelDescriptor)
    Dict("id"=>model.id,"name"=>model.name,"source_id"=>model.source_id,"protocol"=>String(model.protocol),
        "context_window"=>model.context_window,"max_input"=>model.max_input,"max_output"=>model.max_output,"features"=>deepcopy(model.features),
        "operations"=>copy(model.operations),"provenance"=>copy(model.provenance))
end

function catalog_source_id(provider::HTTPProvider)
    config = validate_config(provider.config)
    uri = validate_endpoint(config.endpoint)
    isempty(uri.query) || throw(ShenScopeError(:config,"Model service base URL cannot contain a query"))
    catalog_identifier(config.name;maximum=128,field="provider name")
    digest(canonical(Dict("protocol"=>String(config.protocol),"name"=>config.name,"endpoint"=>rstrip(config.endpoint,'/'))))
end

function configured_model_descriptor(provider::HTTPProvider)
    config = provider.config;capability = config.capabilities
    features = Dict(name=>getfield(capability,Symbol(name)) for name in MODEL_CATALOG_FEATURES)
    provenance = Dict(name=>"configuration" for name in union(MODEL_CATALOG_FEATURES,Set(["name","context_window","max_output","operations"])))
    model_descriptor(config.model,config.model,catalog_source_id(provider),config.protocol;
        context_window=capability.context_window,max_output=capability.max_output,features,operations=["chat"],provenance)
end

struct CatalogSnapshot
    source_id::String
    owner::Tuple{String,String,String}
    access_tag::String
    revision::Int
    models::Vector{ModelDescriptor}
    diagnostics::Vector{CatalogDiagnostic}
    checked_at::String
    checked_time::Float64
    content_sha256::String
    etag::Union{Nothing,String}
    pages::Int
    bytes::Int
end

struct CatalogLease
    key::Tuple{String,String,String,String}
    epoch::Int
    token::CancellationToken
    access_tag::String
    task::Task
end

mutable struct ModelCatalogManager
    snapshots::Dict{Tuple{String,String,String,String},CatalogSnapshot}
    epochs::Dict{Tuple{String,String,String,String},Int}
    running::Dict{Tuple{String,String,String,String},CatalogLease}
    failures::Dict{Tuple{String,String,String,String},String}
    mutex::ReentrantLock
    salt::String
    generation::Int
    max_sources::Int
    max_bytes::Int
    ttl_seconds::Float64
    operations::OperationManager
    closed::Bool
end

function ModelCatalogManager(;max_sources=128,max_bytes=16*1024^2,ttl_seconds=600.0)
    max_sources isa Integer && !(max_sources isa Bool) && 1 <= max_sources <= 512 &&
        max_bytes isa Integer && !(max_bytes isa Bool) && 1024 <= max_bytes <= 64*1024^2 &&
        ttl_seconds isa Real && !(ttl_seconds isa Bool) && isfinite(ttl_seconds) && 0 <= ttl_seconds <= 86400 ||
        throw(ArgumentError("Invalid model catalog capacities"))
    ModelCatalogManager(Dict(),Dict(),Dict(),Dict(),ReentrantLock(),string(uuid4()),0,Int(max_sources),Int(max_bytes),Float64(ttl_seconds),OperationManager(;event_prefix="models"),false)
end

catalog_key(provider::HTTPProvider,ctx::RuntimeContext) = (ctx.root,ctx.state_dir,ctx.session_id,catalog_source_id(provider))
