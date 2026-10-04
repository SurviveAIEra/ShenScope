const EXECUTION_ENVIRONMENT_KEYS = ("LANG","LC_ALL","LC_CTYPE","TZ","TERM","COLORTERM")
const EXECUTION_RUNTIME_ROOTS = ("/usr","/bin","/lib","/lib64")

function execution_string(value,name;max_bytes=4096)
    value isa AbstractString && isvalid(value) && !isempty(value) &&
        ncodeunits(value)<=max_bytes && !occursin('\0',value) && !occursin('\n',value) ||
        throw(ShenScopeError(:config,"Invalid execution "*name))
    String(value)
end

function execution_limits_from_dict(value)
    value isa AbstractDict || throw(ShenScopeError(:config,"Execution limits must be a table"))
    all(key->key in String.(fieldnames(ExecutionLimits)),keys(value)) ||
        throw(ShenScopeError(:config,"Unknown execution resource limit"))
    ExecutionLimits(; (Symbol(key)=>item for (key,item) in value)...)
end

function ExecutionPolicy(;filesystem=:read_only,network=:closed,
        runtime_roots=EXECUTION_RUNTIME_ROOTS,environment_keys=EXECUTION_ENVIRONMENT_KEYS,
        limits=ExecutionLimits())
    filesystem in (:read_only,:workspace_write) ||
        throw(ShenScopeError(:config,"Execution filesystem must be read_only or workspace_write"))
    network in (:closed,:open) || throw(ShenScopeError(:config,"Execution network must be closed or open"))
    runtime_roots isa Union{Tuple,AbstractVector} && length(runtime_roots)<=EXECUTION_MAX_ROOTS ||
        throw(ShenScopeError(:config,"Too many execution runtime roots"))
    roots=String[]
    for root in runtime_roots
        text=execution_string(root,"runtime root")
        isabspath(text) && normpath(text)==text && text!="/" ||
            throw(ShenScopeError(:config,"Execution runtime roots must be normalized absolute paths"))
        push!(roots,text)
    end
    environment_keys isa Union{Tuple,AbstractVector} && length(environment_keys)<=32 ||
        throw(ShenScopeError(:config,"Too many execution environment keys"))
    keys=String[]
    for key in environment_keys
        text=execution_string(key,"environment key";max_bytes=128)
        text in EXECUTION_ENVIRONMENT_KEYS ||
            throw(ShenScopeError(:config,"Execution environment key is not an approved display/locale key"))
        push!(keys,text)
    end
    limits isa ExecutionLimits || throw(ShenScopeError(:config,"Invalid execution limits"))
    ExecutionPolicy(filesystem,network,Tuple(sort!(unique(roots))),Tuple(sort!(unique(keys))),limits)
end

function execution_policy_view(policy::ExecutionPolicy)
    Dict("backend"=>"bubblewrap","filesystem"=>String(policy.filesystem),"network"=>String(policy.network),
        "runtime_roots"=>collect(policy.runtime_roots),"environment_keys"=>collect(policy.environment_keys),
        "limits"=>Dict(String(key)=>getfield(policy.limits,key) for key in fieldnames(ExecutionLimits)))
end

function sandbox_from_config(config::AbstractDict)
    value=get(config,"sandbox",Dict{String,Any}())
    value isa AbstractDict || throw(ShenScopeError(:config,"Sandbox configuration must be a table"))
    all(key->key in ("backend","filesystem","network","runtime_roots","environment_keys","limits"),keys(value)) ||
        throw(ShenScopeError(:config,"Unknown sandbox configuration field"))
    backend=get(value,"backend","host")
    backend isa AbstractString && backend in ("host","bubblewrap") ||
        throw(ShenScopeError(:config,"Sandbox backend must be host or bubblewrap"))
    if backend=="host"
        all(key->key=="backend",keys(value)) ||
            throw(ShenScopeError(:config,"Host execution cannot enforce isolation policy fields"))
        return HostSandbox()
    end
    filesystem=get(value,"filesystem","read_only");network=get(value,"network","closed")
    filesystem isa AbstractString && network isa AbstractString ||
        throw(ShenScopeError(:config,"Sandbox filesystem/network must be strings"))
    BubblewrapSandbox(ExecutionPolicy(;filesystem=Symbol(filesystem),network=Symbol(network),
        runtime_roots=get(value,"runtime_roots",EXECUTION_RUNTIME_ROOTS),
        environment_keys=get(value,"environment_keys",EXECUTION_ENVIRONMENT_KEYS),
        limits=execution_limits_from_dict(get(value,"limits",Dict()))))
end

execution_sandbox_view(::HostSandbox)=Dict("backend"=>"host","os_isolation"=>false,
    "state"=>"host","description"=>"Commands run with host access after process permission.")
execution_sandbox_view(sandbox::BubblewrapSandbox)=merge(execution_policy_view(sandbox.policy),
    Dict("os_isolation"=>false,"state"=>"unprobed",
        "description"=>"Requires a confirmed Linux namespace runner; failure never falls back to host."))
