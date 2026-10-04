mutable struct ModelsTool <: AbstractTool
    provider::HTTPProvider
    manager::ModelCatalogManager
    fleet::Union{Nothing,ModelFleet}
end

function ModelsTool(config=Dict();credential_lookup=key->get(ENV,key,""))
    document = haskey(config,"provider") ? config : DEFAULT_CONFIG
    provider = provider_from_config(document)
    ModelsTool(HTTPProvider(provider.config,credential_lookup;runtime=provider.runtime),ModelCatalogManager(),
        model_routing_from_config(document;credential_lookup))
end
ModelsTool(provider::HTTPProvider,manager::ModelCatalogManager) = ModelsTool(provider,manager,nothing)
tool_name(::ModelsTool) = "models"
tool_description(::ModelsTool) = "Inspect or explicitly refresh a conversation-scoped provider model catalog; measure assembled request inputs with clearly labeled local estimates or implemented provider token-count APIs."
execution_mode(::ModelsTool) = :read

function tool_schema(::ModelsTool)
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["status","list","refresh","inspect","count","clear","health","reset_health","routes","plan"]),
        "model"=>string_schema(;max=512),"offset"=>integer_schema(0),"limit"=>integer_schema(1,100),
        "profile"=>string_schema(;max=64),"role"=>string_schema(;max=64),
        "force"=>Dict("type"=>"boolean"),"max_pages"=>integer_schema(1,32),
        "expected_revision"=>integer_schema(0),"clear_history"=>Dict("type"=>"boolean"),
        "mode"=>Dict("type"=>"string","enum"=>["auto","estimate","provider"]),
        "request"=>Dict("type"=>"object","additionalProperties"=>true));required=["action"])
end

function model_services_status(provider::HTTPProvider)
    Dict("provider"=>provider_name(provider),"protocol"=>String(provider.config.protocol),
        "source_id"=>catalog_source_id(provider),"configured"=>model_descriptor_dict(configured_model_descriptor(provider)),
        "discovery"=>true,"catalog_lifetime"=>"conversation","directory_does_not_change_selection"=>true,
        "count_modes"=>provider.config.protocol in (:anthropic,:gemini) ? ["auto","estimate","provider"] : ["auto","estimate"],
        "provider_count_is_inference_usage"=>false,
        "retry_policy"=>model_retry_policy_dict(provider.runtime.retry_policy),
        "circuit_policy"=>model_circuit_policy_dict(provider.runtime.circuit_policy))
end

function execute(tool::ModelsTool,args::AbstractDict,ctx::RuntimeContext)
    action = args["action"];manager = tool.manager
    if action in ("routes","plan")
        catalog_read_authorize!(ctx)
        action == "routes" && return model_fleet_metadata(tool.fleet,ctx)
        tool.fleet === nothing && throw(ShenScopeError(:config,"Model routing is not configured"))
        request = get(args,"request",nothing)
        request isa AbstractDict || throw(ShenScopeError(:arguments,"Route planning requires an explicit request"))
        route = RoutedProvider(tool.fleet;role=get(args,"role",tool.fleet.default_role))
        result = model_route_plan_dict(model_route_plan(route,model_request_from_dict(request)))
        catalog_read_checkpoint(ctx)
        return result
    end
    provider = model_tool_provider(tool;profile=get(args,"profile",nothing))
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
    elseif action == "health"
        return model_health_snapshot(provider,ctx)
    elseif action == "reset_health"
        return reset_model_health!(provider,ctx;expected_revision=get(args,"expected_revision",nothing),
            clear=get(args,"clear_history",false))
    end
    throw(ShenScopeError(:arguments,"Unknown model service action"))
end

function reset_models_tool!(tool::ModelsTool,config::AbstractDict)
    cleanup_models_tool!(tool)
    provider = provider_from_config(config)
    tool.provider = HTTPProvider(provider.config,tool.provider.credential_lookup;runtime=provider.runtime)
    tool.manager = ModelCatalogManager()
    tool.fleet = model_routing_from_config(config;credential_lookup=tool.provider.credential_lookup)
    nothing
end

function cleanup_models_tool!(tool::ModelsTool)
    cleanup_model_catalogs!(tool.manager)
    close_model_fleet!(tool.fleet)
    close_model_circuits!(tool.provider.runtime.circuits)
    nothing
end

function bind_models_provider!(tools::AbstractVector,provider::AbstractModelProvider)
    if provider isa RoutedProvider
        for tool in tools
            tool isa ModelsTool || continue
            tool.fleet === provider.fleet || close_model_fleet!(tool.fleet)
            tool.fleet = provider.fleet
        end
        return nothing
    end
    provider isa HTTPProvider || return nothing
    for tool in tools
        tool isa ModelsTool || continue
        prior = tool.provider.runtime.circuits
        prior === provider.runtime.circuits || close_model_circuits!(prior)
        tool.provider = HTTPProvider(provider.config,provider.credential_lookup;runtime=provider.runtime)
    end
    nothing
end

function model_tool_provider(tool::ModelsTool;profile=nothing)
    fleet = tool.fleet
    if fleet === nothing
        profile === nothing || throw(ShenScopeError(:arguments,"No model route profile is configured"))
        return tool.provider
    end
    id = profile === nothing ? first(fleet.roles[fleet.default_role].profiles) : profile
    id isa String && haskey(fleet.profiles,id) || throw(ShenScopeError(:arguments,"Unknown model route profile"))
    route_profile_provider(fleet,fleet.profiles[id])
end

function agent_model_provider(tool::ModelsTool;role=nothing)
    if tool.fleet === nothing
        role === nothing || throw(ShenScopeError(:config,"Configure model routing before selecting a role"))
        return HTTPProvider(tool.provider.config,tool.provider.credential_lookup;runtime=tool.provider.runtime)
    end
    RoutedProvider(tool.fleet;role=role === nothing ? tool.fleet.default_role : role)
end

model_worker_role(tool::ModelsTool) = tool.fleet !== nothing && haskey(tool.fleet.roles,"worker") ? "worker" : nothing
