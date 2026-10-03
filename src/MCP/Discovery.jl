const MCP_CATALOG_METHODS = Dict(:tools => ("tools/list", "tools"), :resources => ("resources/list", "resources"),
    :templates => ("resources/templates/list", "resourceTemplates"), :prompts => ("prompts/list", "prompts"))

function mcp_has_capability(client::MCPClient, kind::Symbol; flag = nothing)
    name = kind == :templates ? "resources" : String(kind)
    lock(client.mutex) do
        value = get(client.capabilities, name, nothing)
        value isa AbstractDict && (flag === nothing || get(value, flag, false) === true)
    end
end

function mcp_uri(value, label::String = "resource URI")
    uri = mcp_string(value, label; maximum = 4096)
    occursin(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri) || throw(ShenScopeError(:mcp_protocol, "MCP resource URI must have a scheme"))
    uri
end

function mcp_catalog_item(kind::Symbol, value)
    value isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "MCP catalog entry must be an object"))
    item = Dict{String,Any}(deepcopy(value))
    mcp_string(get(item, "name", nothing), "catalog name"; maximum = 256)
    for field in ("description", "title")
        haskey(item, field) && mcp_string(item[field], "catalog " * field; maximum = 32768, empty = true)
    end
    if kind == :tools
        schema = get(item, "inputSchema", nothing)
        schema isa AbstractDict && get(schema, "type", nothing) == "object" ||
            throw(ShenScopeError(:mcp_schema, "MCP tool input schema must describe an object"))
        check_mcp_schema(schema)
        if haskey(item, "outputSchema")
            output = item["outputSchema"]
            output isa AbstractDict && get(output, "type", nothing) == "object" ||
                throw(ShenScopeError(:mcp_schema, "MCP tool output schema must describe an object"))
            check_mcp_schema(output)
        end
        if haskey(item, "annotations")
            annotations = item["annotations"]
            annotations isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Tool annotations must be an object"))
            for flag in ("readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint")
                haskey(annotations, flag) && !(annotations[flag] isa Bool) &&
                    throw(ShenScopeError(:mcp_protocol, "Tool annotation flag must be boolean"))
            end
        end
    elseif kind in (:resources, :templates)
        mcp_uri(get(item, kind == :resources ? "uri" : "uriTemplate", nothing))
        haskey(item, "mimeType") && mcp_string(item["mimeType"], "resource MIME type"; maximum = 256)
        haskey(item, "size") && mcp_integer(item["size"], "resource size"; maximum = typemax(Int))
    elseif kind == :prompts
        arguments = get(item, "arguments", Any[])
        arguments isa AbstractVector && length(arguments) <= 128 || throw(ShenScopeError(:mcp_protocol, "Invalid prompt argument list"))
        names = Set{String}()
        for argument in arguments
            argument isa AbstractDict || throw(ShenScopeError(:mcp_protocol, "Prompt argument must be an object"))
            name = mcp_string(get(argument, "name", nothing), "prompt argument name"; maximum = 256)
            name in names && throw(ShenScopeError(:mcp_protocol, "Duplicate prompt argument name"))
            push!(names, name)
            haskey(argument, "required") && !(argument["required"] isa Bool) && throw(ShenScopeError(:mcp_protocol, "Prompt required flag must be boolean"))
            haskey(argument, "description") && mcp_string(argument["description"], "prompt argument description"; maximum = 32768, empty = true)
        end
    end
    ncodeunits(canonical(item)) <= 2 * MCP_MAX_SCHEMA_BYTES || throw(ShenScopeError(:mcp_protocol, "Catalog entry exceeds byte capacity"))
    item
end

mcp_catalog_identity(kind::Symbol, item::AbstractDict) = String(item[kind == :resources ? "uri" : kind == :templates ? "uriTemplate" : "name"])

function mcp_fetch_catalog(client::MCPClient, kind::Symbol, ctx::RuntimeContext)
    method, field = MCP_CATALOG_METHODS[kind]
    items = Dict{String,Any}[]
    identities = Set{String}()
    cursors = Set{String}()
    cursor = nothing
    bytes = 0
    for page in 1:MCP_MAX_LIST_PAGES
        params = cursor === nothing ? Dict{String,Any}() : Dict{String,Any}("cursor" => cursor)
        result = mcp_request!(client, method, params, ctx; progress = false)
        result isa AbstractDict && get(result, field, nothing) isa AbstractVector ||
            throw(ShenScopeError(:mcp_protocol, "MCP list result has no item array"))
        raw = result[field]
        length(items) + length(raw) <= MCP_MAX_CATALOG_ITEMS || throw(ShenScopeError(:mcp_capacity, "MCP catalog exceeds item capacity"))
        for value in raw
            item = mcp_catalog_item(kind, value)
            identity = mcp_catalog_identity(kind, item)
            identity in identities && throw(ShenScopeError(:mcp_protocol, "MCP catalog contains duplicate identities"))
            push!(identities, identity)
            bytes += ncodeunits(canonical(item))
            bytes <= 16 * 1024 * 1024 || throw(ShenScopeError(:mcp_capacity, "MCP catalog exceeds total byte capacity"))
            push!(items, item)
        end
        next = get(result, "nextCursor", nothing)
        next === nothing && return items
        cursor = mcp_string(next, "pagination cursor"; maximum = 4096)
        cursor in cursors && throw(ShenScopeError(:mcp_protocol, "MCP pagination cursor repeated"))
        push!(cursors, cursor)
    end
    throw(ShenScopeError(:mcp_capacity, "MCP catalog exceeds pagination capacity"))
end

function mcp_catalog(client::MCPClient, kind::Symbol; ctx = client.context, refresh = false)
    mcp_scope(client, ctx)
    haskey(MCP_CATALOG_METHODS, kind) || throw(ShenScopeError(:mcp_arguments, "Unknown MCP catalog"))
    lock(client.catalog_mutex) do
        client.state == :ready || throw(ShenScopeError(:mcp_unavailable, "MCP server is not connected"))
        if !mcp_has_capability(client, kind)
            return Dict{String,Any}[]
        end
        for attempt in 1:3
            snapshot = lock(client.mutex) do
                catalog = client.catalogs[kind]
                (!refresh && !catalog.dirty && catalog.generation == client.generation) && return deepcopy(catalog.items)
                (client.generation, catalog.revision)
            end
            snapshot isa AbstractVector && return snapshot
            items = mcp_fetch_catalog(client, kind, ctx)
            published = lock(client.mutex) do
                catalog = client.catalogs[kind]
                client.state == :ready && client.generation == snapshot[1] && catalog.revision == snapshot[2] || return false
                catalog.items = items
                catalog.generation = client.generation
                catalog.dirty = false
                true
            end
            published && return deepcopy(items)
        end
        throw(ShenScopeError(:mcp_catalog_changed, "MCP catalog changed repeatedly while being refreshed", true))
    end
end

function mcp_find_tool(client::MCPClient, name::AbstractString, ctx::RuntimeContext)
    identifier = mcp_string(name, "tool name"; maximum = 256)
    items = mcp_catalog(client, :tools; ctx)
    index = findfirst(item -> item["name"] == identifier, items)
    index === nothing && throw(ShenScopeError(:mcp_tool, "MCP server does not offer the requested tool"))
    items[index]
end

function mcp_tool_alias(server::AbstractString, raw_name::AbstractString)
    identity = canonical([String(server), String(raw_name)])
    prefix = replace(String(server) * "_" * String(raw_name), r"[^A-Za-z0-9_]" => "_")
    # Hash the complete identity; truncation never chooses which tool reaches the wire.
    "mcp_" * first(prefix, min(39, length(prefix))) * "_" * first(digest(identity), 20)
end
