function cli_extensions_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Extension action is required"))
    action=positional[2];args=Dict{String,Any}("action"=>action)
    if length(positional)>=3
        args[action in ("inspect_package","load_package") ? "package_name" : "name"]=positional[3]
    end
    for (flag,key) in (("--package-uuid","uuid"),("--package-version","version"),("--entry-sha256","entry_sha256"),
            ("--project-sha256","project_sha256"),("--contribution","contribution"))
        haskey(flags,flag) && (args[key]=flags[flag])
    end
    haskey(flags,"--generation") && (args["generation"]=try;parse(Int,flags["--generation"]);catch;throw(ShenScopeError(:input,"Invalid extension generation"));end)
    haskey(flags,"--arguments") && (args["arguments"]=parsejson(flags["--arguments"]))
    get(flags,"--accept-cleanup-failure",false) && (args["accept_cleanup_failure"]=true)
    policy=permissions_from_config(config)
    for (flag,key) in (("--allow-dynamic",:dynamic),("--allow-process",:process),("--allow-persistence",:persistence))
        get(flags,flag,false) && (policy.rules[key]=Allow)
    end
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,
        sandbox=sandbox_from_config(config),approve=cli_approval,budget=BudgetLedger(limits_from_config(config)))
    tool=ExtensionsTool()
    try
        if action=="invoke"
            haskey(flags,"--package-name") || throw(ShenScopeError(:input,"CLI invocation requires --package-name and inspected package UUID/version/source hashes"))
            package_args=merge(args,Dict("package_name"=>flags["--package-name"]))
            view=load_installed_extension!(tool.registry,extension_package_spec(package_args),ctx)
            view["name"]==get(args,"name",nothing) || throw(ShenScopeError(:conflict,"Installed package registered a different extension name"))
            active=activate_extension!(tool.registry,view["name"],ctx)
            get!(args,"generation",active["generation"])
            args["registry_id"]=active["registry_id"]
        elseif action in ("activate","deactivate","remove","inspect","inspect_tool")
            throw(ShenScopeError(:input,"Use the long-running RPC/agent registry for lifecycle operations; CLI supports list, inspect_package, load_package, load_optional and pinned ephemeral invoke"))
        end
        println(canonical(execute(tool,args,ctx)));0
    finally
        close_extension_registry!(tool.registry)
    end
end
