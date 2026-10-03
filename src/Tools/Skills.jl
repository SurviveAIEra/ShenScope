struct SkillsTool <: AbstractTool
    manager::SkillManager
end
SkillsTool() = SkillsTool(SkillManager())
tool_name(::SkillsTool) = "skills"
tool_description(::SkillsTool) = "Discover project/user SKILL.md metadata; explicitly activate instructions or read confined resources. Skills never grant permissions."
tool_schema(::SkillsTool) = object_schema(Dict("action" => Dict("type" => "string", "enum" => ["list", "reload", "activate", "deactivate", "source", "resource"]),
    "name" => string_schema(; max = 128), "arguments" => string_schema(; max = 16 * 1024),
    "expected_sha256" => string_schema(; max = 64), "path" => string_schema(; max = 4096)); required = ["action"])

function execute(tool::SkillsTool, arguments::AbstractDict, ctx::RuntimeContext; user_requested = false)
    action = arguments["action"]
    action in ("list", "reload") && return skills_list(tool.manager, ctx; reload = action == "reload")
    name = get(arguments, "name", nothing)
    name isa AbstractString || throw(ShenScopeError(:skill_arguments, "Skill action requires a name or catalog ID"))
    if action == "activate"
        return activate_skill!(tool.manager, name, ctx; arguments = get(arguments, "arguments", ""),
            expected_sha256 = get(arguments, "expected_sha256", nothing), user_requested)
    elseif action == "deactivate"
        return deactivate_skill!(tool.manager, name, ctx)
    elseif action == "source"
        return skill_read_source(tool.manager, name, ctx)
    elseif action == "resource"
        path = get(arguments, "path", nothing)
        path isa AbstractString || throw(ShenScopeError(:skill_arguments, "Skill resource requires a relative path"))
        return skill_read_resource(tool.manager, name, path, ctx)
    end
    throw(ShenScopeError(:skill_arguments, "Unknown Skill action"))
end

extra_context(tool::SkillsTool, session::Session, ctx::RuntimeContext) = skill_model_context(tool.manager, session, ctx)
filter_tools(tool::SkillsTool, tools::AbstractVector{<:AbstractTool}, ctx::RuntimeContext) = skill_filter_tools(tool.manager, tools, ctx)
