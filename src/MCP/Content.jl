function mcp_resource_content(value)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP resource content must be an object"))
    mcp_uri(get(value, "uri", nothing))
    xor(haskey(value, "text"), haskey(value, "blob")) || throw(ShenScopeError(:mcp_protocol, "MCP resource must contain text or blob"))
    if haskey(value, "text")
        mcp_string(value["text"], "resource text"; maximum = MCP_MAX_MESSAGE_BYTES, empty = true)
    else
        mcp_base64(value["blob"])
    end
    haskey(value, "mimeType") && mcp_string(value["mimeType"], "resource MIME type"; maximum = 256)
    deepcopy(value)
end

function mcp_base64(value)
    fail() = throw(ShenScopeError(:mcp_protocol, "MCP binary content is not bounded base64"))
    value isa AbstractString && ncodeunits(value) <= MCP_MAX_MESSAGE_BYTES && ncodeunits(value) % 4 == 0 || fail()
    bytes = codeunits(value)
    padding = isempty(bytes) ? 0 : last(bytes) == 0x3d ? (length(bytes) >= 2 && bytes[end - 1] == 0x3d ? 2 : 1) : 0
    for index in eachindex(bytes)
        byte = bytes[index]
        if index > length(bytes) - padding
            byte == 0x3d || fail()
        else
            0x41 <= byte <= 0x5a || 0x61 <= byte <= 0x7a || 0x30 <= byte <= 0x39 || byte in (0x2b, 0x2f) || fail()
        end
    end
    value
end

function mcp_content(value)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP content block must be an object"))
    type = get(value, "type", nothing)
    if type == "text"
        mcp_string(get(value, "text", nothing), "content text"; maximum = MCP_MAX_MESSAGE_BYTES, empty = true)
    elseif type in ("image", "audio")
        mcp_base64(get(value, "data", nothing))
        mcp_string(get(value, "mimeType", nothing), "binary MIME type"; maximum = 256)
    elseif type == "resource"
        mcp_resource_content(get(value, "resource", nothing))
    elseif type == "resource_link"
        mcp_uri(get(value, "uri", nothing))
        mcp_string(get(value, "name", nothing), "resource link name"; maximum = 256)
        haskey(value, "mimeType") && mcp_string(value["mimeType"], "resource link MIME type"; maximum = 256)
    else
        throw(ShenScopeError(:mcp_protocol, "MCP content block type is not supported"))
    end
    if haskey(value, "annotations")
        annotations = value["annotations"]
        annotations isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Content annotations must be an object"))
        if haskey(annotations, "audience")
            audience = annotations["audience"]
            audience isa AbstractVector && all(role -> role in ("user", "assistant"), audience) ||
                throw(ShenScopeError(:mcp_protocol, "Invalid MCP content audience"))
        end
        haskey(annotations, "priority") && mcp_number(annotations["priority"], "content priority"; maximum = 1.0)
    end
    # Preserve all validated content, metadata and structured fields. Resource
    # links are references; reading them requires a separate permissioned call.
    deepcopy(value)
end

function mcp_content_array(values)
    values isa AbstractVector && length(values) <= 1024 || throw(ShenScopeError(:mcp_capacity, "MCP content exceeds block capacity"))
    [mcp_content(value) for value in values]
end

function mcp_tool_result(value, definition::AbstractDict)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP tool result must be an object"))
    get(value, "isError", false) isa Bool || throw(ShenScopeError(:mcp_protocol, "MCP tool error flag must be boolean"))
    result = Dict{String,Any}(deepcopy(value))
    result["content"] = mcp_content_array(get(result, "content", nothing))
    if haskey(result, "structuredContent")
        result["structuredContent"] isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Structured tool content must be an object"))
    end
    if haskey(definition, "outputSchema") && !get(result, "isError", false)
        haskey(result, "structuredContent") || throw(ShenScopeError(:mcp_schema, "MCP tool omitted its declared structured output"))
        validate_mcp_schema(result["structuredContent"], definition["outputSchema"]; path = "structuredContent")
    end
    result
end

function mcp_call_tool!(client::MCPClient, name::AbstractString, arguments::AbstractDict,
        ctx::RuntimeContext = client.context; expected_definition = nothing)
    definition = mcp_find_tool(client, name, ctx)
    expected_definition === nothing || digest(canonical(definition)) == expected_definition ||
        throw(ShenScopeError(:mcp_catalog_changed, "MCP tool definition changed; refresh the tool declaration", true))
    validate_mcp_schema(arguments, definition["inputSchema"])
    result = mcp_request!(client, "tools/call", Dict("name" => String(name), "arguments" => deepcopy(arguments)), ctx)
    mcp_tool_result(result, definition)
end

function mcp_read_resource!(client::MCPClient, uri::AbstractString, ctx::RuntimeContext = client.context)
    mcp_has_capability(client, :resources) || throw(ShenScopeError(:mcp_capability, "MCP server does not offer resources"))
    target = mcp_uri(uri)
    result = mcp_request!(client, "resources/read", Dict("uri" => target), ctx)
    result isa AbstractDict && get(result, "contents", nothing) isa AbstractVector && length(result["contents"]) <= 1024 ||
        throw(ShenScopeError(:mcp_protocol, "Invalid MCP resource result"))
    Dict{String,Any}(merge(deepcopy(result), Dict("contents" => [mcp_resource_content(item) for item in result["contents"]])))
end

function mcp_get_prompt!(client::MCPClient, name::AbstractString, arguments::AbstractDict = Dict(),
        ctx::RuntimeContext = client.context)
    identifier = mcp_string(name, "prompt name"; maximum = 256)
    items = mcp_catalog(client, :prompts; ctx)
    index = findfirst(item -> item["name"] == identifier, items)
    index === nothing && throw(ShenScopeError(:mcp_prompt, "MCP server does not offer the requested prompt"))
    specs = get(items[index], "arguments", Any[])
    permitted = Set(argument["name"] for argument in specs)
    all(key -> key in permitted, keys(arguments)) || throw(ShenScopeError(:mcp_arguments, "Unknown MCP prompt argument"))
    for argument in specs
        get(argument, "required", false) && !haskey(arguments, argument["name"]) &&
            throw(ShenScopeError(:mcp_arguments, "Required MCP prompt argument is missing"))
    end
    for value in values(arguments); mcp_string(value, "prompt argument"; maximum = 65536, empty = true); end
    result = mcp_request!(client, "prompts/get", Dict("name" => identifier, "arguments" => deepcopy(arguments)), ctx)
    result isa AbstractDict && get(result, "messages", nothing) isa AbstractVector && length(result["messages"]) <= 256 ||
        throw(ShenScopeError(:mcp_protocol, "Invalid MCP prompt result"))
    for message in result["messages"]
        message isa AbstractDict && get(message, "role", nothing) in ("user", "assistant") ||
            throw(ShenScopeError(:mcp_protocol, "Invalid MCP prompt message role"))
        mcp_content(get(message, "content", nothing))
    end
    deepcopy(result)
end

function mcp_subscribe!(client::MCPClient, uri::AbstractString, ctx::RuntimeContext = client.context; unsubscribe = false)
    mcp_has_capability(client, :resources; flag = "subscribe") || throw(ShenScopeError(:mcp_capability, "MCP server does not offer resource subscriptions"))
    target = mcp_uri(uri)
    lock(client.subscription_mutex) do
        generation, prior = lock(client.mutex) do
            prior = target in client.subscriptions
            !unsubscribe && length(client.subscriptions) >= 128 && !prior &&
                throw(ShenScopeError(:mcp_capacity, "MCP resource subscription capacity reached"))
            !unsubscribe && push!(client.subscriptions, target)
            get!(client.resource_versions, target, 0)
            (client.generation, prior)
        end
        try
            result = mcp_request!(client, unsubscribe ? "resources/unsubscribe" : "resources/subscribe", Dict("uri" => target), ctx; progress = false)
            result isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Invalid MCP subscription response"))
            lock(client.mutex) do
                client.generation == generation && client.state == :ready || throw(ShenScopeError(:mcp_transport, "MCP connection changed during subscription"))
                unsubscribe && delete!(client.subscriptions, target)
            end
        catch
            lock(client.mutex) do
                client.generation == generation && !prior && !unsubscribe && delete!(client.subscriptions, target)
            end
            rethrow()
        end
    end
    Dict("uri" => target, "subscribed" => !unsubscribe)
end

function mcp_complete!(client::MCPClient, reference::AbstractDict, argument::AbstractDict,
        ctx::RuntimeContext = client.context; arguments = Dict())
    mcp_has_capability(client, :completions) || throw(ShenScopeError(:mcp_capability, "MCP server does not offer completions"))
    type = get(reference, "type", nothing)
    type in ("ref/prompt", "ref/resource") || throw(ShenScopeError(:mcp_arguments, "Invalid MCP completion reference"))
    Set(keys(reference)) == Set(["type", type == "ref/prompt" ? "name" : "uri"]) || throw(ShenScopeError(:mcp_arguments, "Invalid completion reference fields"))
    type == "ref/prompt" ? mcp_string(reference["name"], "prompt name"; maximum = 256) : mcp_uri(reference["uri"])
    Set(keys(argument)) == Set(["name", "value"]) || throw(ShenScopeError(:mcp_arguments, "Completion argument requires name and value"))
    mcp_string(argument["name"], "completion argument name"; maximum = 256)
    mcp_string(argument["value"], "completion argument value"; maximum = 4096, empty = true)
    arguments isa AbstractDict && length(arguments) <= 128 || throw(ShenScopeError(:mcp_arguments, "Invalid completion context arguments"))
    for (key, value) in arguments
        mcp_string(key, "completion context name"; maximum = 256)
        mcp_string(value, "completion context value"; maximum = 4096, empty = true)
    end
    result = mcp_request!(client, "completion/complete", Dict("ref" => deepcopy(reference), "argument" => deepcopy(argument),
        "context" => Dict("arguments" => deepcopy(arguments))), ctx; progress = false)
    result isa AbstractDict && get(result, "completion", nothing) isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Invalid MCP completion result"))
    completion = result["completion"]
    values = get(completion, "values", nothing)
    values isa AbstractVector && length(values) <= 100 && all(value -> value isa AbstractString && ncodeunits(value) <= 4096, values) ||
        throw(ShenScopeError(:mcp_protocol, "Invalid MCP completion values"))
    haskey(completion, "total") && mcp_integer(completion["total"], "completion total"; maximum = typemax(Int))
    haskey(completion, "hasMore") && !(completion["hasMore"] isa Bool) && throw(ShenScopeError(:mcp_protocol, "Completion hasMore must be boolean"))
    deepcopy(result)
end
