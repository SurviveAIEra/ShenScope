function cli_serve_command(positional,flags,config,state_dir)
    get(flags,"--stdio",false) || throw(ShenScopeError(:input,"Use serve --stdio"))
    factory=haskey(flags,"--script") ? s->scripted_provider(flags["--script"]) : nothing
    return serve_stdio(CoreServer(get(flags,"--root",pwd());state_dir,
        config_file=get(flags,"--config",config_path()),provider_factory=factory))
end
