function route_config_table(document,allowed;field="model routing")
    document isa AbstractDict && all(key->key isa String,keys(document)) ||
        throw(ShenScopeError(:config,field*" must be a string-keyed table"))
    all(key->key in allowed,keys(document)) || throw(ShenScopeError(:config,"Unknown "*field*" option"))
    document
end

function route_config_id(value;field="model routing identifier")
    value isa String && occursin(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$",value) ||
        throw(ShenScopeError(:config,"Invalid "*field))
    value
end

function route_config_json(value;kwargs...)
    try
        bounded_canonical_json(value;kwargs...)
    catch error
        error isa ShenScopeError || rethrow()
        throw(ShenScopeError(:config,"Invalid or oversized model routing declaration"))
    end
end

function route_profile_options(document)
    document isa AbstractDict || throw(ShenScopeError(:config,"Model profile options must be a table"))
    encoded = route_config_json(document;maximum=64*1024,max_depth=12,max_nodes=4096)
    decoded = parsejson(encoded)
    pending = Any[decoded]
    forbidden = Set(["apikey","accesstoken","bearertoken","authorization","password","secret","token","privatekey"])
    while !isempty(pending)
        value = pop!(pending)
        if value isa AbstractDict
            for (key,item) in value
                normalized = replace(lowercase(key),r"[^a-z0-9]"=>"")
                normalized in forbidden && throw(ShenScopeError(:config,"Model profile credentials must use secure key bindings"))
                item isa AbstractDict || item isa AbstractVector || continue
                push!(pending,item)
            end
        elseif value isa AbstractVector
            for item in value
                item isa AbstractDict || item isa AbstractVector || continue
                push!(pending,item)
            end
        end
    end
    decoded
end

function route_config_text(value;maximum=512,field="model selection")
    value isa String && isvalid(value) && 1 <= ncodeunits(value) <= maximum && strip(value) == value &&
        !any(iscntrl,value) || throw(ShenScopeError(:config,"Invalid "*field))
    value
end

function route_profile_capabilities(document,base::ModelCapabilities)
    route_config_table(document,String.(fieldnames(ModelCapabilities));field="model profile capabilities")
    values = Dict{Symbol,Any}(name=>getfield(base,name) for name in fieldnames(ModelCapabilities))
    for (key,value) in document
        if key in ("context_window","max_output")
            value isa Integer && !(value isa Bool) && 1 <= value <= 4_000_000 ||
                throw(ShenScopeError(:config,"Invalid model profile capacity"))
            values[Symbol(key)] = Int(value)
        else
            value isa Bool || throw(ShenScopeError(:config,"Invalid model profile feature declaration"))
            values[Symbol(key)] = value
        end
    end
    values[:max_output] < values[:context_window] ||
        throw(ShenScopeError(:config,"Model profile output capacity must leave input space"))
    ModelCapabilities(;values...)
end

function route_provider_config(base::ProviderConfig,model::String,capability::ModelCapabilities)
    ProviderConfig(;protocol=base.protocol,name=base.name,endpoint=base.endpoint,model,
        key_env=base.key_env,timeout=base.timeout,retries=base.retries,input_price=base.input_price,
        output_price=base.output_price,capabilities=capability)
end

function route_profile_provider(fleet::ModelFleet,profile::ModelProfile)
    source = fleet.providers[profile.selection.provider_id]
    HTTPProvider(route_provider_config(source.config,profile.selection.model,profile.capabilities),
        source.credential_lookup;runtime=source.runtime)
end

function model_routing_from_config(config::AbstractDict;credential_lookup=key->get(ENV,key,""))
    document = get(config,"model_routing",nothing)
    document === nothing && return nothing
    route_config_table(document,("providers","profiles","roles","default_role");field="model routing")
    route_config_json(document;maximum=1024^2,max_depth=16,max_nodes=32_000)
    declarations = get(document,"providers",nothing)
    declarations isa AbstractDict && 1 <= length(declarations) <= 32 ||
        throw(ShenScopeError(:config,"Model routing requires 1 to 32 providers"))
    circuits = ModelCircuitManager()
    providers = Dict{String,HTTPProvider}();seen_sources = Set{String}()
    for (id,declaration) in declarations
        route_config_id(id;field="route provider identifier")
        route_config_table(declaration,("protocol","name","endpoint","key_env","timeout","retries",
            "input_price","output_price","capabilities","retry_policy","circuit");field="route provider")
        all(key->haskey(declaration,key),("protocol","name","endpoint","key_env")) ||
            throw(ShenScopeError(:config,"Route provider requires protocol, name, endpoint and key_env"))
        for field in ("protocol","name","endpoint","key_env");route_config_text(declaration[field];field="route provider "*field);end
        for field in ("timeout","input_price","output_price")
            haskey(declaration,field) || continue
            value = declaration[field]
            value isa Real && !(value isa Bool) && isfinite(value) && (field == "timeout" ? value > 0 : value >= 0) ||
                throw(ShenScopeError(:config,"Invalid route provider numeric limit"))
        end
        base = deepcopy(DEFAULT_CONFIG["provider"]);merge_config!(base,declaration)
        base["model"] = "configured-by-profile"
        source = provider_from_config(Dict("provider"=>base))
        identity = catalog_source_id(source)
        identity in seen_sources && throw(ShenScopeError(:config,"Duplicate route provider source identity"))
        push!(seen_sources,identity)
        runtime = ModelProviderRuntime(;retry_policy=source.runtime.retry_policy,
            circuit_policy=source.runtime.circuit_policy,circuits)
        providers[id] = HTTPProvider(source.config,credential_lookup;runtime)
    end
    declarations = get(document,"profiles",nothing)
    declarations isa AbstractDict && 1 <= length(declarations) <= 128 ||
        throw(ShenScopeError(:config,"Model routing requires 1 to 128 profiles"))
    profiles = Dict{String,ModelProfile}()
    for (id,declaration) in declarations
        route_config_id(id;field="model profile identifier")
        route_config_table(declaration,("provider","model","description","options","capabilities");field="model profile")
        provider_id = route_config_id(get(declaration,"provider",nothing);field="profile provider reference")
        haskey(providers,provider_id) || throw(ShenScopeError(:config,"Model profile references an unknown provider"))
        model = route_config_text(get(declaration,"model",nothing);field="profile model")
        description = get(declaration,"description","")
        description isa String && isvalid(description) && ncodeunits(description) <= 2048 &&
            !any(character->iscntrl(character) && !(character in ('\n','\t')),description) ||
            throw(ShenScopeError(:config,"Invalid model profile description"))
        options = route_profile_options(get(declaration,"options",Dict()))
        safe = Dict{String,Any}();merge_config!(safe,options)
        encoded = route_config_json(safe;maximum=64*1024,max_depth=12,max_nodes=4096)
        source = providers[provider_id]
        capability = route_profile_capabilities(get(declaration,"capabilities",Dict()),capabilities(source))
        profile = ModelProfile(id,description,ModelSelection(provider_id,model,encoded),capability)
        # Assembling a small request validates protected fields without keys or HTTP.
        wire = HTTPProvider(route_provider_config(source.config,model,capability),credential_lookup;runtime=source.runtime)
        model_body(wire,ModelRequest([Message(:user,"profile validation")],Dict{String,Any}[],1,safe))
        profiles[id] = profile
    end
    declarations = get(document,"roles",nothing)
    declarations isa AbstractDict && 1 <= length(declarations) <= 32 ||
        throw(ShenScopeError(:config,"Model routing requires 1 to 32 roles"))
    roles = Dict{String,ModelRoleRoute}()
    for (role,declaration) in declarations
        route_config_id(role;field="model role")
        route_config_table(declaration,("profiles","fallback_codes");field="model role route")
        ids = get(declaration,"profiles",nothing)
        ids isa AbstractVector && 1 <= length(ids) <= 8 ||
            throw(ShenScopeError(:config,"Model role route requires 1 to 8 ordered profiles"))
        all(id->id isa String && haskey(profiles,id),ids) && length(Set(ids)) == length(ids) ||
            throw(ShenScopeError(:config,"Model role route contains an unknown or repeated profile"))
        codes = get(declaration,"fallback_codes",collect(String.(MODEL_ROUTE_FALLBACK_CODES)))
        codes isa AbstractVector && length(codes) <= length(MODEL_ROUTE_FALLBACK_CODES) &&
            all(code->code isa String && Symbol(code) in MODEL_ROUTE_FALLBACK_CODES,codes) &&
            length(Set(codes)) == length(codes) || throw(ShenScopeError(:config,"Invalid route fallback categories"))
        roles[role] = ModelRoleRoute(role,Tuple(String.(ids)),Tuple(Symbol.(codes)))
    end
    default_role = route_config_id(get(document,"default_role",nothing);field="default model role")
    haskey(roles,default_role) || throw(ShenScopeError(:config,"Unknown default model role"))
    revision = digest(bounded_canonical_json(document;maximum=1024^2,max_depth=16,max_nodes=32_000))
    ModelFleet(providers,profiles,roles,default_role,revision,circuits,Dict(),Dict{String,Any}[],
        ReentrantLock(),16,64,false)
end

function RoutedProvider(fleet::ModelFleet;role=fleet.default_role)
    role isa String && haskey(fleet.roles,role) || throw(ShenScopeError(:config,"Unknown model route role"))
    lock(fleet.mutex) do;fleet.closed && throw(ShenScopeError(:runtime,"Model routing runtime is closed"));end
    RoutedProvider(fleet,role)
end
