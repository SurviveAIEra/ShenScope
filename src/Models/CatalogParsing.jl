struct CatalogPage
    models::Vector{ModelDescriptor}
    diagnostics::Vector{CatalogDiagnostic}
    cursor::Union{Nothing,String}
    raw_count::Int
end

function catalog_page_models(protocol::Symbol,data::AbstractDict)
    field = protocol in (:gemini,:ollama) ? "models" : "data"
    entries = get(data,field,nothing)
    entries isa AbstractVector || throw(ShenScopeError(:protocol,"Model catalog is missing its model array"))
    length(entries) <= 1024 || throw(ShenScopeError(:capacity,"Model catalog page exceeds entry capacity"))
    entries
end

function catalog_model_features(raw::AbstractDict)
    features = get(raw,"capabilities",Dict())
    features isa AbstractDict || throw(ShenScopeError(:catalog,"Model capabilities must be an object"))
    Dict{String,Any}(field=>features[field] for field in MODEL_CATALOG_FEATURES if haskey(features,field))
end

function catalog_gemini_operations(raw::AbstractDict)
    methods = get(raw,"supportedGenerationMethods",nothing)
    methods === nothing && return String[]
    methods isa AbstractVector && length(methods) <= 64 && all(value -> value isa AbstractString,methods) ||
        throw(ShenScopeError(:catalog,"Invalid Gemini generation methods"))
    mapped = Dict("generateContent"=>"chat","streamGenerateContent"=>"chat","countTokens"=>"count_tokens",
        "embedContent"=>"embed","batchEmbedContents"=>"embed","generateImages"=>"image")
    sort!(unique([mapped[value] for value in methods if haskey(mapped,value)]))
end

function catalog_parse_model(provider::HTTPProvider,raw::AbstractDict)
    protocol = provider.config.protocol;source = catalog_source_id(provider)
    if protocol == :gemini
        full_name = catalog_identifier(get(raw,"name",nothing))
        startswith(full_name,"models/") || throw(ShenScopeError(:catalog,"Gemini model name is outside the models namespace"))
        id = catalog_identifier(full_name[8:end])
        context = get(raw,"context_window",nothing)
        input = get(raw,"inputTokenLimit",nothing);output = get(raw,"outputTokenLimit",nothing)
        name = get(raw,"displayName",id);operations = catalog_gemini_operations(raw)
    elseif protocol == :ollama
        id = catalog_identifier(get(raw,"name",get(raw,"model",nothing)))
        name = id;context = get(raw,"context_window",nothing)
        input = get(raw,"max_input_tokens",nothing);output = get(raw,"max_output_tokens",nothing)
        operations = String[]
    else
        id = catalog_identifier(get(raw,"id",nothing));name = get(raw,"display_name",get(raw,"name",id))
        context = get(raw,"context_window",nothing)
        input = get(raw,"max_input_tokens",nothing);output = get(raw,"max_output_tokens",nothing)
        type = get(raw,"type",nothing)
        operations = type in ("chat","embed","image") ? [type] : String[]
    end
    features = catalog_model_features(raw)
    provenance = Dict("name"=>"provider_api")
    context === nothing || (provenance["context_window"] = "provider_api")
    input === nothing || (provenance["max_input"] = "provider_api")
    output === nothing || (provenance["max_output"] = "provider_api")
    isempty(operations) || (provenance["operations"] = "provider_api")
    for (field,value) in features;value === nothing || (provenance[field] = "provider_api");end
    model_descriptor(id,name,source,protocol;context_window=context,max_input=input,max_output=output,features,operations,provenance)
end

function catalog_diagnostic_id(provider::HTTPProvider,entry::AbstractDict)
    candidate = provider.config.protocol == :gemini ? get(entry,"name",nothing) :
        provider.config.protocol == :ollama ? get(entry,"name",get(entry,"model",nothing)) : get(entry,"id",nothing)
    candidate isa AbstractString && isvalid(candidate) && 1 <= ncodeunits(candidate) <= 512 && !any(iscntrl,candidate) || return nothing
    provider.config.protocol == :gemini && startswith(candidate,"models/") && (candidate = candidate[8:end])
    isempty(candidate) ? nothing : String(candidate)
end

function catalog_page_cursor(protocol::Symbol,data::AbstractDict,raw::AbstractVector)
    if protocol == :gemini
        value = get(data,"nextPageToken",nothing)
        value in (nothing,"") && return nothing
        return catalog_identifier(value;maximum=2048,field="catalog cursor")
    elseif protocol == :ollama
        return nothing
    end
    more = get(data,"has_more",false)
    more isa Bool || throw(ShenScopeError(:protocol,"Catalog pagination flag must be Boolean"))
    more || return nothing
    isempty(raw) && throw(ShenScopeError(:protocol,"Catalog has more pages without entries"))
    cursor = get(data,"last_id",nothing)
    if cursor === nothing
        last = raw[end]
        last isa AbstractDict || throw(ShenScopeError(:protocol,"Catalog pagination has no usable cursor"))
        cursor = get(last,"id",nothing)
    end
    catalog_identifier(cursor;maximum=2048,field="catalog cursor")
end

function parse_catalog_page(provider::HTTPProvider,data::AbstractDict)
    raw = catalog_page_models(provider.config.protocol,data)
    models = ModelDescriptor[];diagnostics = CatalogDiagnostic[]
    for entry in raw
        if !(entry isa AbstractDict)
            push!(diagnostics,CatalogDiagnostic(nothing,:entry,"Model entry is not an object"))
            continue
        end
        try
            push!(models,catalog_parse_model(provider,entry))
        catch cause
            cause isa ShenScopeError || rethrow()
            push!(diagnostics,CatalogDiagnostic(catalog_diagnostic_id(provider,entry),cause.code,cause.message))
        end
    end
    CatalogPage(models,diagnostics,catalog_page_cursor(provider.config.protocol,data,raw),length(raw))
end

function merge_catalog_page!(models::Dict{String,ModelDescriptor},invalid::Set{String},
        diagnostics::Vector{CatalogDiagnostic},page::CatalogPage)
    append!(diagnostics,page.diagnostics)
    for diagnostic in page.diagnostics
        diagnostic.model_id === nothing && continue
        delete!(models,diagnostic.model_id);push!(invalid,diagnostic.model_id)
    end
    for model in page.models
        if model.id in invalid
            continue
        elseif haskey(models,model.id)
            delete!(models,model.id);push!(invalid,model.id)
            push!(diagnostics,CatalogDiagnostic(model.id,:duplicate,"Duplicate model ID invalidates all entries with that ID"))
        else
            models[model.id] = model
        end
    end
    length(models)+length(invalid)+length(diagnostics) <= MODEL_CATALOG_MAX_MODELS ||
        throw(ShenScopeError(:capacity,"Model catalog exceeds its combined entry/diagnostic capacity"))
    nothing
end
