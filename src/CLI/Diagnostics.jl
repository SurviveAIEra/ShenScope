function cli_diagnostics_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Diagnostics action required"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-dynamic",false) && (policy.rules[:dynamic]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,approve=cli_approval)
    args=Dict{String,Any}("action"=>positional[2])
    length(positional)>=3 && (args["target"]=positional[3])
    tool=DiagnosticsTool();validate_schema(args,tool_schema(tool));println(canonical(execute(tool,args,ctx)));return 0
end
