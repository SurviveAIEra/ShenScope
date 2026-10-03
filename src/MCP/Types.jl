abstract type AbstractMCPTransport end

const MCP_SUPPORTED_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
const MCP_DEFAULT_VERSION = first(MCP_SUPPORTED_VERSIONS)
const MCP_MAX_MESSAGE_BYTES = 8 * 1024 * 1024
const MCP_MAX_SCHEMA_BYTES = 256 * 1024
const MCP_MAX_PENDING = 32
const MCP_MAX_CATALOG_ITEMS = 1000
const MCP_MAX_LIST_PAGES = 100
const MCP_MAX_NOTIFICATIONS = 128
const MCP_MAX_SERVER_REQUESTS = 8

function mcp_string(value, label::String; maximum = 4096, empty = false)
    value isa AbstractString && isvalid(value) && !occursin('\0', value) &&
        ncodeunits(value) <= maximum && (empty || !isempty(strip(value))) ||
        throw(ShenScopeError(:mcp_config, "Invalid " * label))
    String(value)
end

function mcp_number(value, label::String; minimum = 0.0, maximum = 3600.0)
    value isa Real && !(value isa Bool) && isfinite(value) && minimum <= value <= maximum ||
        throw(ShenScopeError(:mcp_config, "Invalid " * label))
    Float64(value)
end

function mcp_integer(value, label::String; minimum = 0, maximum = 1000)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:mcp_config, "Invalid " * label))
    Int(value)
end

function mcp_json_value(value; depth = 0, count = Ref(0), max_bytes = MCP_MAX_MESSAGE_BYTES)
    depth <= 64 || throw(ShenScopeError(:mcp_protocol, "MCP JSON nesting exceeds capacity"))
    count[] += 1
    count[] <= 100000 || throw(ShenScopeError(:mcp_protocol, "MCP JSON item count exceeds capacity"))
    if value isa AbstractDict
        for (key, child) in value
            key isa AbstractString && isvalid(key) && ncodeunits(key) <= 4096 ||
                throw(ShenScopeError(:mcp_protocol, "Invalid MCP JSON key"))
            mcp_json_value(child; depth = depth + 1, count, max_bytes)
        end
    elseif value isa AbstractVector
        for child in value
            mcp_json_value(child; depth = depth + 1, count, max_bytes)
        end
    elseif value isa AbstractString
        isvalid(value) && ncodeunits(value) <= max_bytes || throw(ShenScopeError(:mcp_protocol, "MCP string exceeds capacity"))
    elseif value isa AbstractFloat
        isfinite(value) || throw(ShenScopeError(:mcp_protocol, "MCP numbers must be finite"))
    elseif !(value === nothing || value isa Bool || value isa Integer)
        throw(ShenScopeError(:mcp_protocol, "MCP data must be JSON"))
    end
    value
end

struct MCPServerSpec
    name::String
    transport::Symbol
    argv::Vector{String}
    endpoint::String
    cwd::String
    environment_env::Dict{String,String}
    header_env::Dict{String,String}
    timeout::Float64
    connect_timeout::Float64
    max_message_bytes::Int
    reconnect_attempts::Int
    reconnect_delay::Float64
    stability_seconds::Float64
    enabled::Bool
end

function mcp_environment_name(value)
    name = mcp_string(value, "environment variable"; maximum = 128)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", name) || throw(ShenScopeError(:mcp_config, "Invalid environment variable name"))
    name
end

function mcp_server_name(value)
    name = mcp_string(value, "server name"; maximum = 128)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", name) ||
        throw(ShenScopeError(:mcp_config, "MCP server name must use letters, numbers, dots, underscores or dashes"))
    name
end

function mcp_env_bindings(values, kind::Symbol)
    values isa AbstractVector && length(values) <= 32 || throw(ShenScopeError(:mcp_config, "Invalid MCP environment bindings"))
    result = Dict{String,String}()
    protected = Set(["host", "content-length", "transfer-encoding", "connection", "origin", "accept",
        "content-type", "mcp-session-id", "mcp-protocol-version", "last-event-id"])
    for value in values
        value isa AbstractDict && Set(keys(value)) == Set(["name", "env"]) ||
            throw(ShenScopeError(:mcp_config, "Environment bindings require name and env"))
        name = kind == :header ? mcp_string(value["name"], "HTTP header"; maximum = 128) : mcp_environment_name(value["name"])
        if kind == :header
            occursin(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", name) && !(lowercase(name) in protected) ||
                throw(ShenScopeError(:mcp_config, "HTTP header is invalid or owned by the transport"))
        end
        identity = kind == :header ? lowercase(name) : name
        any(existing -> (kind == :header ? lowercase(existing) : existing) == identity, keys(result)) &&
            throw(ShenScopeError(:mcp_config, "Duplicate MCP environment binding"))
        result[name] = mcp_environment_name(value["env"])
    end
    result
end

function MCPServerSpec(name::AbstractString, config::AbstractDict)
    identifier = mcp_server_name(name)
    allowed = Set(["transport", "argv", "endpoint", "cwd", "environment_env", "header_env", "timeout",
        "connect_timeout", "max_message_bytes", "reconnect_attempts", "reconnect_delay", "stability_seconds", "enabled"])
    all(key -> key in allowed, keys(config)) || throw(ShenScopeError(:mcp_config, "Unknown MCP server configuration field"))
    transport = Symbol(mcp_string(get(config, "transport", "stdio"), "transport"; maximum = 16))
    transport in (:stdio, :http) || throw(ShenScopeError(:mcp_config, "MCP transport must be stdio or http"))
    raw_argv = get(config, "argv", String[])
    raw_argv isa AbstractVector && length(raw_argv) <= 64 || throw(ShenScopeError(:mcp_config, "Invalid MCP command arguments"))
    argv = [mcp_string(item, "command argument"; empty = true, maximum = 16384) for item in raw_argv]
    endpoint = mcp_string(get(config, "endpoint", ""), "endpoint"; empty = true)
    if transport == :stdio
        !isempty(argv) && !isempty(first(argv)) && isempty(endpoint) || throw(ShenScopeError(:mcp_config, "Stdio MCP requires argv only"))
    else
        isempty(argv) && !isempty(endpoint) || throw(ShenScopeError(:mcp_config, "HTTP MCP requires endpoint only"))
        uri = try HTTP.URI(endpoint) catch; throw(ShenScopeError(:mcp_config, "Invalid MCP endpoint")); end
        uri.scheme in ("http", "https") && !isempty(uri.host) && isempty(uri.userinfo) && isempty(uri.fragment) ||
            throw(ShenScopeError(:mcp_config, "MCP endpoint must be HTTP(S) without embedded credentials or fragment"))
    end
    environment = mcp_env_bindings(get(config, "environment_env", Any[]), :environment)
    headers = mcp_env_bindings(get(config, "header_env", Any[]), :header)
    transport == :stdio && !isempty(headers) && throw(ShenScopeError(:mcp_config, "Stdio MCP does not use HTTP headers"))
    transport == :http && !isempty(environment) && throw(ShenScopeError(:mcp_config, "HTTP MCP does not use child environment bindings"))
    enabled = get(config, "enabled", true)
    enabled isa Bool || throw(ShenScopeError(:mcp_config, "MCP enabled must be boolean"))
    MCPServerSpec(identifier, transport, argv, endpoint,
        mcp_string(get(config, "cwd", "."), "working directory"), environment, headers,
        mcp_number(get(config, "timeout", 30.0), "request timeout"; minimum = 0.1),
        mcp_number(get(config, "connect_timeout", 30.0), "connection timeout"; minimum = 0.1),
        mcp_integer(get(config, "max_message_bytes", MCP_MAX_MESSAGE_BYTES), "message capacity"; minimum = 1024, maximum = MCP_MAX_MESSAGE_BYTES),
        mcp_integer(get(config, "reconnect_attempts", 3), "reconnection attempts"; maximum = 10),
        mcp_number(get(config, "reconnect_delay", 0.25), "reconnection delay"; minimum = 0.01, maximum = 60),
        mcp_number(get(config, "stability_seconds", 30.0), "connection stability period"; minimum = 1), enabled)
end

function mcp_spec_dict(spec::MCPServerSpec)
    Dict("transport" => String(spec.transport), "argv" => copy(spec.argv), "endpoint" => spec.endpoint,
        "cwd" => spec.cwd, "environment_env" => [Dict("name" => key, "env" => value) for (key, value) in sort!(collect(spec.environment_env))],
        "header_env" => [Dict("name" => key, "env" => value) for (key, value) in sort!(collect(spec.header_env))],
        "timeout" => spec.timeout, "connect_timeout" => spec.connect_timeout, "max_message_bytes" => spec.max_message_bytes,
        "reconnect_attempts" => spec.reconnect_attempts, "reconnect_delay" => spec.reconnect_delay,
        "stability_seconds" => spec.stability_seconds, "enabled" => spec.enabled)
end

mcp_permission_target(spec::MCPServerSpec) = "mcp:" * spec.name * ":" * digest(canonical(mcp_spec_dict(spec)))

struct MCPRemoteError <: Exception
    code::Int
    message::String
    data::Any
end
Base.showerror(io::IO, error::MCPRemoteError) = print(io, "MCP server rejected request (", error.code, "): ", error.message)

mutable struct MCPPending
    id::String
    method::String
    generation::Int
    context::RuntimeContext
    result::Channel{Any}
    progress_token::String
    progress::Float64
    submitted::Bool
end

mutable struct MCPCatalog
    items::Vector{Dict{String,Any}}
    revision::Int
    dirty::Bool
    generation::Int
end
MCPCatalog() = MCPCatalog(Dict{String,Any}[], 0, true, 0)

mutable struct MCPInboundRequest
    generation::Int
    context::RuntimeContext
    task::Union{Nothing,Task}
end

mutable struct MCPClient
    spec::MCPServerSpec
    context::RuntimeContext
    credential_lookup::Function
    transport::Union{Nothing,AbstractMCPTransport}
    state::Symbol
    generation::Int
    protocol_version::String
    server_info::Dict{String,Any}
    capabilities::Dict{String,Any}
    instructions::String
    pending::Dict{String,MCPPending}
    catalogs::Dict{Symbol,MCPCatalog}
    subscriptions::Set{String}
    resource_versions::Dict{String,Int}
    notifications::Vector{Dict{String,Any}}
    server_requests::Dict{String,MCPInboundRequest}
    connected_at::Float64
    consecutive_failures::Int
    last_error::Union{Nothing,Dict{String,Any}}
    reconnect_task::Union{Nothing,Task}
    lifetime_task::Union{Nothing,Task}
    stopping::Bool
    mutex::ReentrantLock
    lifecycle_mutex::ReentrantLock
    catalog_mutex::ReentrantLock
    subscription_mutex::ReentrantLock
end

function MCPClient(spec::MCPServerSpec, ctx::RuntimeContext; credential_lookup = key -> get(ENV, key, ""))
    MCPClient(spec, child_context(ctx), credential_lookup, nothing, :disconnected, 0, "",
        Dict{String,Any}(), Dict{String,Any}(), "", Dict{String,MCPPending}(),
        Dict(kind => MCPCatalog() for kind in (:tools, :resources, :templates, :prompts)),
        Set{String}(), Dict{String,Int}(), Dict{String,Any}[], Dict{String,MCPInboundRequest}(),
        0.0, 0, nothing, nothing, nothing, false, ReentrantLock(), ReentrantLock(), ReentrantLock(), ReentrantLock())
end
