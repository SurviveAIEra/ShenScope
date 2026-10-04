const DEFAULT_CONFIG=Dict{String,Any}(
    "provider"=>Dict{String,Any}("protocol"=>"openai_chat","name"=>"openai-compatible",
        "endpoint"=>"https://api.openai.com/v1","model"=>"gpt-4.1","key_env"=>"SHENSCOPE_MODEL_KEY",
        "timeout"=>120.0,"retries"=>2,"input_price"=>0.0,"output_price"=>0.0),
    "budget"=>Dict{String,Any}("max_steps"=>100,"max_tokens"=>1_000_000,"max_cost"=>10.0,"max_seconds"=>3600.0),
    "permissions"=>Dict{String,Any}("read"=>"allow","edit"=>"ask","process"=>"ask",
        "network"=>"ask","mcp"=>"ask","dynamic"=>"ask","persistence"=>"ask"),
    "mcp"=>Dict{String,Any}("servers"=>Dict{String,Any}()),
    "skills"=>Dict{String,Any}(),
    "hooks"=>Dict{String,Any}(),
    "context"=>Dict{String,Any}())

function merge_config!(target::Dict,source::AbstractDict)
    for (k,v) in source
        lowercase(k) in ("api_key","token","secret","password","authorization") &&
            throw(ShenScopeError(:config,"Credentials must use environment or secure storage, not TOML"))
        if v isa AbstractDict
            existing=get!(target,k,Dict{String,Any}())
            existing isa AbstractDict || throw(ShenScopeError(:config,"Configuration shape conflict"))
            merge_config!(existing,v)
        else
            target[k]=v
        end
    end
    return target
end

function config_path()
    get(ENV,"SHENSCOPE_CONFIG",joinpath(homedir(),".config/shenscope/config.toml"))
end
function load_config(;path=config_path(),profile=nothing)
    config=deepcopy(DEFAULT_CONFIG)
    if isfile(path)
        filesize(path)<=1024*1024 || throw(ShenScopeError(:config,"Configuration too large"))
        doc=TOML.parsefile(path)
        profiles=pop!(doc,"profiles",Dict())
        merge_config!(config,doc)
        if profile!==nothing
            haskey(profiles,profile) || throw(ShenScopeError(:config,"Unknown configuration profile"))
            merge_config!(config,profiles[profile])
        end
    elseif profile!==nothing
        throw(ShenScopeError(:config,"No configuration profiles defined"))
    end
    provider_from_config(config)
    fleet = model_routing_from_config(config)
    close_model_fleet!(fleet)
    BudgetLedger(limits_from_config(config))
    permissions_from_config(config)
    mcp_specs_from_config(config)
    skill_config(config)
    hook_config(config)
    context_config(config)
    return config
end

function provider_from_config(config::AbstractDict)
    p=config["provider"]
    p["retries"] isa Integer && !(p["retries"] isa Bool) || throw(ShenScopeError(:config,"Model retry count must be an integer"))
    document = get(p, "capabilities", Dict())
    document isa AbstractDict || throw(ShenScopeError(:config, "Provider capabilities must be a table"))
    names = Set(String.(fieldnames(ModelCapabilities)))
    all(key -> key in names, keys(document)) || throw(ShenScopeError(:config, "Unknown model capability"))
    values = Dict{Symbol,Any}()
    for (key, value) in document
        if key in ("context_window", "max_output")
            value isa Integer && !(value isa Bool) && 1 <= value <= 4_000_000 ||
                throw(ShenScopeError(:config, "Invalid model capacity"))
        else
            value isa Bool || throw(ShenScopeError(:config, "Model capability must be Boolean"))
        end
        values[Symbol(key)] = value
    end
    capability = ModelCapabilities(; values...)
    c=ProviderConfig(;protocol=Symbol(p["protocol"]),name=p["name"],endpoint=p["endpoint"],model=p["model"],
        key_env=p["key_env"],timeout=p["timeout"],retries=p["retries"],
        input_price=p["input_price"],output_price=p["output_price"],capabilities=capability)
    retry = model_retry_policy_from_dict(get(p,"retry_policy",Dict());max_retries=c.retries)
    circuit = model_circuit_policy_from_dict(get(p,"circuit",Dict()))
    runtime = ModelProviderRuntime(;retry_policy=retry,circuit_policy=circuit)
    return HTTPProvider(validate_config(c);runtime)
end
limits_from_config(c::AbstractDict)=BudgetLimits(;max_steps=c["budget"]["max_steps"],max_tokens=c["budget"]["max_tokens"],
    max_cost=c["budget"]["max_cost"],max_seconds=c["budget"]["max_seconds"])
function permissions_from_config(config::AbstractDict)
    values=Dict("allow"=>Allow,"ask"=>Ask,"deny"=>Deny)
    rules=Dict{Symbol,PermissionDecision}()
    for (k,v) in config["permissions"]
        haskey(values,v) || throw(ShenScopeError(:config,"Permission must be allow, ask or deny"))
        rules[Symbol(k)]=values[v]
    end
    return PermissionPolicy(;rules)
end

function save_config!(config::Dict;path=config_path(),expected_sha256=nothing,before_write=()->nothing)
    return store_lock(path) do
        if expected_sha256!==nothing
            observed=isfile(path) ? digest(read(path,String)) : digest("")
            observed==expected_sha256 || throw(ShenScopeError(:conflict,"Configuration changed"))
        end
        sanitized=merge_config!(Dict{String,Any}(),config)
        context_config(sanitized)
        provider_from_config(sanitized);BudgetLedger(limits_from_config(sanitized));permissions_from_config(sanitized);mcp_specs_from_config(sanitized);skill_config(sanitized);hook_config(sanitized)
        fleet = model_routing_from_config(sanitized);close_model_fleet!(fleet)
        io=IOBuffer();TOML.print(io,sanitized;sorted=true)
        text=String(take!(io));before_write();atomic_write(path,text)
        return digest(text)
    end
end
