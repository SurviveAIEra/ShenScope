#!/usr/bin/env julia
# Run from the repository with --startup-file=no --threads=4 --project=.
# Each invocation measures a fresh process, with the existing package cache.
started_ns = time_ns()
using ShenScope
loaded_ns = time_ns()

function startup_phase(value)
    Dict("seconds"=>value.time,"allocated_bytes"=>value.bytes,"gc_seconds"=>value.gctime,
        "compile_seconds"=>value.compile_time,"recompile_seconds"=>value.recompile_time)
end

mktempdir(;prefix="shenscope-startup-") do root
    config_file = joinpath(root,"config.toml")
    write(config_file,"""
        [provider]
        endpoint = "https://example.invalid"
        model = "startup-fixture"
        key_env = "SHENSCOPE_STARTUP_UNUSED"
        [permissions]
        read = "allow"
        process = "deny"
        network = "deny"
        persistence = "deny"
        """)
    output = IOBuffer()
    construction = @timed CoreServer(root;state_dir=joinpath(root,"state"),config_file,output)
    server = construction.value
    try
        initialization = @timed Base.invokelatest(dispatch_rpc,server,"initialize",
            Dict{String,Any}("protocol_version"=>PROTOCOL_VERSION))
        health = @timed Base.invokelatest(dispatch_rpc,server,"health",Dict{String,Any}())
        settings = @timed Base.invokelatest(dispatch_rpc,server,"config/get",Dict{String,Any}())
        session = @timed Base.invokelatest(dispatch_rpc,server,"sessions/create",
            Dict{String,Any}("title"=>"Startup fixture"))
        models = @timed Base.invokelatest(dispatch_rpc,server,"models/query",
            Dict{String,Any}("session_id"=>session.value["id"]))
        println(canonical(Dict("julia"=>string(Base.VERSION),"threads"=>Threads.nthreads(),
            "module_load_seconds"=>(loaded_ns-started_ns)/1e9,
            "construction"=>startup_phase(construction),"initialize"=>startup_phase(initialization),
            "health"=>startup_phase(health),"config_get"=>startup_phase(settings),
            "session_create"=>startup_phase(session),"models_status"=>startup_phase(models),
            "elapsed_seconds"=>(time_ns()-started_ns)/1e9,
            "scope"=>"temporary local metadata fixture; no child process or model request; session writes cleaned")))
    finally
        stop_server!(server)
    end
end
