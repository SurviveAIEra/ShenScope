function cli_runtime_image_command(positional,flags,config,state_dir)
    length(positional)>=2 || throw(ShenScopeError(:input,"Runtime image action is required"))
    action=positional[2]
    action=="loaded" && (println(canonical(runtime_loaded_image_view()));return 0)
    policy=permissions_from_config(config)
    get(flags,"--allow-dynamic",false) && (policy.rules[:dynamic]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,approve=cli_approval,
        sandbox=sandbox_from_config(config),budget=BudgetLedger(limits_from_config(config)))
    if action=="source"
        println(canonical(runtime_source_view(runtime_source_snapshot(ctx))));return 0
    end
    length(positional)==3 && action in ("inspect","verify","plan") ||
        throw(ShenScopeError(:input,"Use runtime-image source | loaded | inspect RECEIPT | verify RECEIPT | plan RECEIPT"))
    if action=="inspect"
        println(canonical(runtime_image_inspect(abspath(positional[3]),ctx)));return 0
    end
    image=runtime_image_verify(abspath(positional[3]),ctx)
    if action=="plan"
        println(canonical(runtime_image_launch_arguments(image,ctx)))
    else
        println(canonical(Dict("verified"=>true,"image_sha256"=>image.image_sha256,
            "source_fingerprint"=>image.source_fingerprint,"julia_version"=>string(image.julia_version),
            "machine"=>image.machine,"cpu_target"=>image.cpu_target,"signature_verified"=>false,
            "compiled_instructions_attested"=>false)))
    end
    0
end
