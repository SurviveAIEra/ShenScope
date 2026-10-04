using PrecompileTools: @setup_workload, @compile_workload

# Capture the metadata path used by both IDEs. All filesystem effects stay in a
# disposable fixture; no user configuration, model request or process is used.
# Preferences can disable this workload through PrecompileTools' normal switch.
@setup_workload begin
    mktempdir(;prefix="shenscope-precompile-") do root
        config_file = joinpath(root,"config.toml")
        write(config_file,"""
            [provider]
            endpoint = "https://example.invalid"
            model = "precompile-fixture"
            key_env = "SHENSCOPE_PRECOMPILE_UNUSED"
            [permissions]
            read = "allow"
            process = "deny"
            network = "deny"
            persistence = "deny"
            """)
        @compile_workload begin
            output = IOBuffer()
            server = CoreServer(root;state_dir=joinpath(root,"state"),config_file,output)
            try
                # Dynamic method names/parameters match framed RPC dispatch.
                for (id,method,params) in (
                        (1,"initialize",Dict{String,Any}("protocol_version"=>PROTOCOL_VERSION)),
                        (2,"health",Dict{String,Any}()),
                        (3,"config/get",Dict{String,Any}()),
                        (4,"sessions/create",Dict{String,Any}("title"=>"Precompile fixture")))
                    handle_rpc(server,Dict{String,Any}("jsonrpc"=>"2.0","id"=>id,
                        "method"=>method,"params"=>params))
                end
                seekstart(output)
                replies = [read_rpc(output) for _ in 1:4]
                all(reply->haskey(reply,"result"),replies) || error("Metadata precompile fixture failed")
                session_id = replies[4]["result"]["id"]
                seekend(output)
                response_offset = position(output)
                handle_rpc(server,Dict{String,Any}("jsonrpc"=>"2.0","id"=>5,
                    "method"=>"models/query","params"=>Dict{String,Any}("session_id"=>session_id)))
                seek(output,response_offset)
                haskey(read_rpc(output),"result") || error("Model metadata precompile fixture failed")
                seekend(output)
                input = IOBuffer()
                write_rpc(input,Dict{String,Any}("jsonrpc"=>"2.0","id"=>6,"method"=>"health"))
                write_rpc(input,Dict{String,Any}("jsonrpc"=>"2.0","id"=>7,"method"=>"shutdown"))
                seekstart(input)
                serve_stdio(server;input)
            finally
                stop_server!(server)
            end
            # Compile the command and real pipe entry points without running a
            # terminal or taking ownership of package-manager stdin/stdout.
            precompile(main,(Vector{String},))
            precompile(cli_serve_command,(Vector{String},Dict{String,Any},Dict{String,Any},String))
            precompile(read_rpc,(Base.PipeEndpoint,))
        end
    end
end
