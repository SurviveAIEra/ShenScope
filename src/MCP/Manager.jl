mutable struct MCPJob
    id::String
    server::String
    action::String
    context::RuntimeContext
    status::Symbol
    result::Any
    error::Union{Nothing,String}
    task::Union{Nothing,Task}
end

mutable struct MCPManager
    specs::Dict{String,MCPServerSpec}
    clients::Dict{Tuple{String,String,String},MCPClient}
    jobs::Dict{String,MCPJob}
    credential_lookup::Function
    mutex::ReentrantLock
    ownership_mutex::ReentrantLock
end

function mcp_specs_from_config(config::AbstractDict)
    section = get(config, "mcp", Dict())
    section isa AbstractDict && all(key -> key == "servers", keys(section)) ||
        throw(ShenScopeError(:mcp_config, "MCP configuration requires a servers section"))
    servers = get(section, "servers", Dict())
    servers isa AbstractDict && length(servers) <= 32 || throw(ShenScopeError(:mcp_config, "MCP server configuration exceeds capacity"))
    specs = Dict{String,MCPServerSpec}()
    for (name, value) in servers
        name isa AbstractString && value isa AbstractDict || throw(ShenScopeError(:mcp_config, "Invalid MCP server configuration"))
        spec = MCPServerSpec(name, value)
        specs[spec.name] = spec
    end
    specs
end

function MCPManager(config::AbstractDict = Dict(); credential_lookup = key -> get(ENV, key, ""))
    MCPManager(mcp_specs_from_config(config), Dict{Tuple{String,String,String},MCPClient}(),
        Dict{String,MCPJob}(), credential_lookup, ReentrantLock(), ReentrantLock())
end

function mcp_client!(manager::MCPManager, name::AbstractString, ctx::RuntimeContext; owner = ctx)
    identifier = mcp_server_name(name)
    ctx.root == owner.root && ctx.session_id == owner.session_id || throw(ShenScopeError(:mcp_scope, "MCP request owner does not match its session"))
    key = (ctx.root, ctx.session_id, identifier)
    lock(manager.ownership_mutex) do
      stale = lock(manager.mutex) do
        spec = get(manager.specs, identifier, nothing)
        spec === nothing && throw(ShenScopeError(:mcp_config, "MCP server is not configured"))
        prior = get(manager.clients, key, nothing)
        if prior !== nothing && iscancelled(prior.context.cancellation)
            delete!(manager.clients, key)
            return prior
        end
        nothing
    end
      stale !== nothing && mcp_disconnect!(stale)
      lock(manager.mutex) do
        get!(manager.clients, key) do
            length(manager.clients) < 64 || throw(ShenScopeError(:mcp_capacity, "MCP connection capacity reached"))
            MCPClient(manager.specs[identifier], owner; credential_lookup = manager.credential_lookup)
        end
      end
    end
end

function mcp_servers(manager::MCPManager, ctx::RuntimeContext)
    lock(manager.mutex) do
        [begin
            spec = manager.specs[name]
            client = get(manager.clients, (ctx.root, ctx.session_id, name), nothing)
            status = client === nothing ? Dict{String,Any}("name" => name, "transport" => String(spec.transport),
                "state" => spec.enabled ? "disconnected" : "disabled", "generation" => 0) : mcp_status(client)
            merge(status, Dict("enabled" => spec.enabled))
        end for name in sort!(collect(keys(manager.specs)))]
    end
end

function mcp_job_view(job::MCPJob)
    Dict("job_id" => job.id, "server" => job.server, "action" => job.action, "status" => String(job.status),
        "result" => deepcopy(job.result), "error" => job.error)
end

function cleanup_mcp!(manager::MCPManager; session_id = nothing, root = nothing)
    clients, jobs = lock(manager.mutex) do
        selected = [key for key in keys(manager.clients) if (session_id === nothing || key[2] == session_id) &&
            (root === nothing || key[1] == root)]
        clients = [pop!(manager.clients, key) for key in selected]
        jobs = [job for job in values(manager.jobs) if (session_id === nothing || job.context.session_id == session_id) &&
            (root === nothing || job.context.root == root)]
        (clients, jobs)
    end
    for job in jobs; cancel!(job.context.cancellation, "MCP owner stopped"); end
    for client in clients; mcp_disconnect!(client); end
    for job in jobs
        job.task !== nothing && job.task !== current_task() && try wait(job.task) catch end
    end
    nothing
end
