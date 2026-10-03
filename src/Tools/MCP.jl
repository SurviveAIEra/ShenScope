struct MCPControlTool <: AbstractTool
    manager::MCPManager
end
MCPControlTool() = MCPControlTool(MCPManager())
tool_name(::MCPControlTool) = "mcp"
tool_description(::MCPControlTool) = "Inspect configured MCP servers; connect explicitly, discover tools/resources/prompts and make permissioned calls."

function tool_schema(::MCPControlTool)
    object_schema(Dict("action" => Dict("type" => "string", "enum" => ["servers", "connect", "disconnect", "reconnect", "status",
        "ping", "tools", "resources", "templates", "prompts", "call", "read", "prompt", "subscribe", "unsubscribe", "complete"]),
        "server" => string_schema(; max = 128), "name" => string_schema(; max = 256), "uri" => string_schema(; max = 4096),
        "arguments" => Dict("type" => "object"), "reference" => Dict("type" => "object"),
        "argument" => Dict("type" => "object"), "refresh" => Dict("type" => "boolean")); required = ["action"])
end

function mcp_required(arguments::AbstractDict, field::String)
    haskey(arguments, field) || throw(ShenScopeError(:mcp_arguments, "MCP action requires " * field))
    arguments[field]
end

function execute(tool::MCPControlTool, arguments::AbstractDict, ctx::RuntimeContext; owner = ctx)
    action = get(arguments, "action", "")
    action == "servers" && return mcp_servers(tool.manager, ctx)
    name = mcp_required(arguments, "server")
    client = mcp_client!(tool.manager, name, ctx; owner)
    if action == "connect"
        return mcp_connect!(client; ctx)
    elseif action == "disconnect"
        return mcp_disconnect!(client)
    elseif action == "reconnect"
        return mcp_reconnect!(client; ctx)
    elseif action == "status"
        return mcp_status(client)
    end
    client.state == :ready || throw(ShenScopeError(:mcp_unavailable, "Connect the MCP server before using its capabilities"))
    if action == "ping"
        return mcp_test_connection!(client, ctx)
    elseif action in ("tools", "resources", "templates", "prompts")
        return mcp_catalog(client, Symbol(action); ctx, refresh = get(arguments, "refresh", false))
    elseif action == "call"
        return mcp_call_tool!(client, mcp_required(arguments, "name"), get(arguments, "arguments", Dict()), ctx)
    elseif action == "read"
        return mcp_read_resource!(client, mcp_required(arguments, "uri"), ctx)
    elseif action == "prompt"
        return mcp_get_prompt!(client, mcp_required(arguments, "name"), get(arguments, "arguments", Dict()), ctx)
    elseif action in ("subscribe", "unsubscribe")
        return mcp_subscribe!(client, mcp_required(arguments, "uri"), ctx; unsubscribe = action == "unsubscribe")
    elseif action == "complete"
        return mcp_complete!(client, mcp_required(arguments, "reference"), mcp_required(arguments, "argument"), ctx;
            arguments = get(arguments, "arguments", Dict()))
    end
    throw(ShenScopeError(:mcp_arguments, "Unknown MCP action"))
end

struct MCPRemoteTool <: AbstractTool
    client::MCPClient
    definition::Dict{String,Any}
    definition_hash::String
    alias::String
end

function MCPRemoteTool(client::MCPClient, definition::AbstractDict)
    MCPRemoteTool(client, Dict{String,Any}(deepcopy(definition)), digest(canonical(definition)),
        mcp_tool_alias(client.spec.name, definition["name"]))
end

tool_name(tool::MCPRemoteTool) = tool.alias
tool_schema(tool::MCPRemoteTool) = deepcopy(tool.definition["inputSchema"])
tool_description(tool::MCPRemoteTool) = "MCP " * tool.client.spec.name * "/" * tool.definition["name"] * ": " *
    cliptext(string(get(tool.definition, "description", "")), 4096)
# Remote readOnly/idempotent hints are untrusted; effects use the exclusive barrier.
execution_mode(::MCPRemoteTool) = :exclusive
is_successful_tool_result(::MCPRemoteTool, value) = !get(value, "isError", false)
tool_failure_message(::MCPRemoteTool, value) = get(value, "isError", false) ? "MCP tool reported an error" : nothing
is_successful_tool_result(::MCPControlTool, value) = !(value isa AbstractDict && get(value, "isError", false))
tool_failure_message(::MCPControlTool, value) = value isa AbstractDict && get(value, "isError", false) ? "MCP tool reported an error" : nothing

function execute(tool::MCPRemoteTool, arguments::AbstractDict, ctx::RuntimeContext)
    result = mcp_call_tool!(tool.client, tool.definition["name"], arguments, ctx; expected_definition = tool.definition_hash)
    result
end

function validate_tool_arguments(tool::MCPRemoteTool, arguments)
    validate_mcp_schema(arguments, tool.definition["inputSchema"])
end

function additional_tools(tool::MCPControlTool, ctx::RuntimeContext)
    clients = lock(tool.manager.mutex) do
        [client for (key, client) in tool.manager.clients if key[1] == ctx.root && key[2] == ctx.session_id &&
            client.state == :ready && !iscancelled(client.context.cancellation)]
    end
    sort!(clients; by = client -> client.spec.name)
    result = AbstractTool[]
    for client in clients
        try
            for definition in mcp_catalog(client, :tools; ctx)
                length(result) < 128 || throw(ShenScopeError(:mcp_capacity, "Active MCP tool declaration capacity reached"))
                push!(result, MCPRemoteTool(client, definition))
            end
        catch error
            error isa ShenScopeError && error.code == :cancelled && rethrow()
            emit!(ctx, :mcp_catalog_error, Dict("server" => client.spec.name, "code" => error isa ShenScopeError ? String(error.code) : "internal"))
        end
    end
    result
end
