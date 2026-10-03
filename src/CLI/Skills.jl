function cli_skills_command(positional::Vector{String}, flags::AbstractDict, config::AbstractDict, state_dir::String)
    length(positional) >= 2 || throw(ShenScopeError(:input, "Use skills list, reload, activate, deactivate, source or resource"))
    action = positional[2]
    arguments = Dict{String,Any}("action" => action)
    if action ∉ ("list", "reload")
        length(positional) >= 3 || throw(ShenScopeError(:input, "Skill name or catalog ID required"))
        arguments["name"] = positional[3]
        action == "activate" && (arguments["arguments"] = join(positional[4:end], " "))
        if action == "resource"
            length(positional) == 4 || throw(ShenScopeError(:input, "Skill relative resource path required"))
            arguments["path"] = positional[4]
        end
    end
    policy = permissions_from_config(config)
    get(flags, "--allow-persistence", false) && (policy.rules[:persistence] = Allow)
    ctx = RuntimeContext(get(flags, "--root", pwd()); session_id = get(flags, "--session", string(uuid4())), state_dir,
        permissions = policy, approve = cli_approval)
    manager = SkillManager(config)
    tool = SkillsTool(manager)
    if action in ("activate", "deactivate")
        haskey(flags, "--session") || throw(ShenScopeError(:input, "Skills activation requires --session ID"))
        bind_skills_session!(manager, load_session(state_dir, ctx.session_id), ctx)
        restore_skills!(manager, skill_session!(manager, ctx), ctx)
    end
    try
        validate_tool_arguments(tool, arguments)
        println(canonical(with_context(() -> execute(tool, arguments, ctx; user_requested = true), ctx)))
        0
    finally
        cleanup_skills!(manager)
    end
end
