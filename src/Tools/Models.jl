mutable struct ModelsTool <: AbstractTool
    provider::HTTPProvider
    manager::ModelCatalogManager
end

function ModelsTool(config=Dict();credential_lookup=key->get(ENV,key,""))
    document = haskey(config,"provider") ? config : DEFAULT_CONFIG
    ModelsTool(HTTPProvider(provider_from_config(document).config,credential_lookup),ModelCatalogManager())
end
tool_name(::ModelsTool) = "models"
tool_description(::ModelsTool) = "Inspect or explicitly refresh a conversation-scoped provider model catalog; measure assembled request inputs with clearly labeled local estimates or implemented provider token-count APIs."
execution_mode(::ModelsTool) = :read

function tool_schema(::ModelsTool)
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["status","list","refresh","inspect","count","clear"]),
        "model"=>string_schema(;max=512),"offset"=>integer_schema(0),"limit"=>integer_schema(1,100),
        "force"=>Dict("type"=>"boolean"),"max_pages"=>integer_schema(1,32),
        "mode"=>Dict("type"=>"string","enum"=>["auto","estimate","provider"]),
        "request"=>Dict("type"=>"object","additionalProperties"=>true));required=["action"])
end

function model_services_status(provider::HTTPProvider)
    Dict("provider"=>provider_name(provider),"protocol"=>String(provider.config.protocol),
        "source_id"=>catalog_source_id(provider),"configured"=>model_descriptor_dict(configured_model_descriptor(provider)),
        "discovery"=>true,"catalog_lifetime"=>"conversation","directory_does_not_change_selection"=>true,
        "count_modes"=>provider.config.protocol in (:anthropic,:gemini) ? ["auto","estimate","provider"] : ["auto","estimate"],
        "provider_count_is_inference_usage"=>false)
end

function execute(tool::ModelsTool,args::AbstractDict,ctx::RuntimeContext)
    action = args["action"];provider = tool.provider;manager = tool.manager
    if action == "status"
        catalog_read_authorize!(ctx)
        return model_services_status(provider)
    elseif action == "list"
        return model_catalog_view(manager,provider,ctx;offset=get(args,"offset",0),limit=get(args,"limit",50))
    elseif action == "refresh"
        return refresh_model_catalog!(manager,provider,ctx;force=get(args,"force",false),max_pages=get(args,"max_pages",16),
            offset=get(args,"offset",0),limit=get(args,"limit",50))
    elseif action == "inspect"
        catalog_read_authorize!(ctx)
        id = get(args,"model",nothing)
        id isa AbstractString || throw(ShenScopeError(:arguments,"Model identifier is required"))
        source = catalog_key(provider,ctx)
        key = CredentialSnapshot(provider.credential_lookup(provider.config.key_env))
        access = catalog_access_tag(manager,key)
        snapshot = lock(manager.mutex) do;deepcopy(get(manager.snapshots,source,nothing));end
        configured = configured_model_descriptor(provider)
        discovered = snapshot === nothing || snapshot.access_tag != access ? nothing : findfirst(model -> model.id == id,snapshot.models)
        configured.id == id || discovered !== nothing || throw(ShenScopeError(:catalog,"Model is not in this conversation's catalog"))
        return Dict("configured"=>configured.id == id ? model_descriptor_dict(configured) : nothing,
            "discovered"=>discovered === nothing ? nothing : model_descriptor_dict(snapshot.models[discovered]),
            "fields_are_declarations"=>true,"selection_changed"=>false)
    elseif action == "count"
        request = get(args,"request",nothing)
        request isa AbstractDict || throw(ShenScopeError(:arguments,"Explicit assembled request is required"))
        return count_model_tokens(provider,model_request_from_dict(request),ctx;mode=Symbol(get(args,"mode","auto")))
    elseif action == "clear"
        return forget_model_catalog!(manager,provider,ctx)
    end
    throw(ShenScopeError(:arguments,"Unknown model service action"))
end

function reset_models_tool!(tool::ModelsTool,config::AbstractDict)
    cleanup_model_catalogs!(tool.manager)
    tool.provider = HTTPProvider(provider_from_config(config).config,tool.provider.credential_lookup)
    tool.manager = ModelCatalogManager()
    nothing
end
