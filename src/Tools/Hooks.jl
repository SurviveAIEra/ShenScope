struct HooksTool <: AbstractTool
    manager::HookManager
end
HooksTool() = HooksTool(HookManager())
tool_name(::HooksTool) = "hooks"
tool_description(::HooksTool) = "Inspect or reload configured lifecycle Hooks. Explicit command tests are user operations. Hooks do not grant permissions or alter tool results."
tool_schema(::HooksTool) = object_schema(Dict("action"=>Dict("type"=>"string", "enum"=>["list", "reload", "recent", "source", "test"]),
    "name"=>string_schema(;max=128)); required=["action"])

function execute(tool::HooksTool, arguments::AbstractDict, ctx::RuntimeContext; user_requested=false)
    action = arguments["action"]
    action in ("list", "reload") && return hooks_list(tool.manager, ctx; reload=action == "reload")
    if action == "recent"
        hooks_list(tool.manager, ctx)
        return lock(tool.manager.mutex) do
            Dict("history"=>deepcopy([item for item in tool.manager.history if item["session_id"] == ctx.session_id && item["root"] == ctx.root]))
        end
    end
    name = get(arguments, "name", nothing)
    name isa AbstractString || throw(ShenScopeError(:hook_arguments, "Hook action requires a name or source ID"))
    action == "source" && return hooks_read_configuration(tool.manager, name, ctx)
    if action == "test"
        user_requested || throw(ShenScopeError(:hook_scope, "Hook command tests require explicit user invocation"))
        catalog = hook_catalog!(tool.manager, ctx)
        spec = hook_find(catalog, name)
        metadata = isempty(spec.tools) ? Dict{String,Any}() : Dict{String,Any}("tool"=>first(spec.tools))
        return hook_outcome_view(run_hook!(tool.manager, catalog, spec, ctx; metadata, testing=true))
    end
    throw(ShenScopeError(:hook_arguments, "Unsupported Hook action"))
end
