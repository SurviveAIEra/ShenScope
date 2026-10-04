function cli_doctor_command(positional,flags,config,state_dir)
    p=provider_from_config(config)
    println(canonical(Dict("version"=>string(VERSION),"julia"=>string(Base.VERSION),
        "provider"=>provider_name(p),"protocol"=>String(p.config.protocol),"model"=>p.config.model,
        "key_configured"=>!isempty(get(ENV,p.config.key_env,"")),"key_variable"=>p.config.key_env,
        "state_dir"=>abspath(state_dir),"config_path"=>get(flags,"--config",config_path()),
        "sandbox"=>"host process; OS isolation not configured")))
    return 0
end
