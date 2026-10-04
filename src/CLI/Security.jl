function cli_security_command(positional,flags,config,state_dir)
    length(positional)==2 || throw(ShenScopeError(:input,"Use security status or security probe"))
    positional[2] in ("status","probe") || throw(ShenScopeError(:input,"Unknown security action"))
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,session_id=get(flags,"--session","cli-security"),
        sandbox=sandbox_from_config(config),permissions=policy,budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    tool=SecurityTool()
    try
        println(canonical(execute(tool,Dict("action"=>positional[2]),ctx)))
    finally
        cleanup_execution!(tool.manager)
    end
    0
end
