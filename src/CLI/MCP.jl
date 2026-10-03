function cli_mcp_arguments(ctx::RuntimeContext, path::String)
    file = workspace_path(ctx.root, path; must_exist = true)
    authorize!(ctx, :read, "mcp.arguments", file; reason = "Read MCP action arguments")
    filesize(file) <= 256 * 1024 || throw(ShenScopeError(:input, "MCP arguments file exceeds capacity"))
    value = try parsejson(read(file, String)) catch; throw(ShenScopeError(:input, "MCP arguments file is not valid JSON")); end
    value isa AbstractDict || throw(ShenScopeError(:input, "MCP arguments file must contain an object"))
    Dict{String,Any}(value)
end

function cli_mcp_command(positional::Vector{String}, flags::AbstractDict, config::AbstractDict, state_dir::String)
    length(positional) >= 2 || throw(ShenScopeError(:input, "Use mcp servers, connect, tools, call, resources, read, prompts or prompt"))
    policy = permissions_from_config(config)
    for (flag, category) in (("--allow-process", :process), ("--allow-network", :network), ("--allow-mcp", :mcp))
        get(flags, flag, false) && (policy.rules[category] = Allow)
    end
    ctx = RuntimeContext(get(flags, "--root", pwd()); state_dir, session_id = get(flags, "--session", "cli-mcp"),
        permissions = policy, approve = cli_approval)
    action = positional[2]
    arguments = Dict{String,Any}("action" => action)
    if action != "servers"
        length(positional) >= 3 || throw(ShenScopeError(:input, "MCP server name required"))
        arguments["server"] = positional[3]
        if action in ("call", "prompt")
            length(positional) >= 4 || throw(ShenScopeError(:input, "MCP tool or prompt name required"))
            arguments["name"] = positional[4]
            arguments["arguments"] = length(positional) >= 5 ? cli_mcp_arguments(ctx, positional[5]) : Dict()
        elseif action in ("read", "subscribe", "unsubscribe")
            length(positional) == 4 || throw(ShenScopeError(:input, "MCP resource URI required"))
            arguments["uri"] = positional[4]
        elseif action == "complete"
            length(positional) == 4 || throw(ShenScopeError(:input, "MCP completion arguments JSON file required"))
            merge!(arguments, cli_mcp_arguments(ctx, positional[4]))
            arguments["action"] = action
            arguments["server"] = positional[3]
        end
    end
    tool = MCPControlTool(MCPManager(config))
    try
        validate_tool_arguments(tool, arguments)
        if action ∉ ("servers", "connect", "status", "disconnect")
            execute(tool, Dict("action" => "connect", "server" => arguments["server"]), ctx)
        end
        value = with_context(() -> execute(tool, arguments, ctx), ctx)
        println(canonical(value))
        return is_successful_tool_result(tool, value) ? 0 : 1
    finally
        cleanup_mcp!(tool.manager)
    end
end
