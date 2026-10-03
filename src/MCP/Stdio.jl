mutable struct MCPLineDecoder
    pending::Vector{UInt8}
    maximum::Int
end
MCPLineDecoder(maximum = MCP_MAX_MESSAGE_BYTES) = MCPLineDecoder(UInt8[], maximum)

function feed_mcp_lines!(callback::Function, decoder::MCPLineDecoder, data::AbstractVector{UInt8})
    offset = 1
    while offset <= length(data)
        newline = findnext(==(0x0a), data, offset)
        ending = newline === nothing ? length(data) : newline - 1
        added = max(0, ending - offset + 1)
        length(decoder.pending) + added <= decoder.maximum || throw(ShenScopeError(:mcp_protocol, "MCP stdio message exceeds capacity"))
        added > 0 && append!(decoder.pending, @view data[offset:ending])
        newline === nothing && break
        !isempty(decoder.pending) && last(decoder.pending) == 0x0d && pop!(decoder.pending)
        if !isempty(decoder.pending)
            raw = String(copy(decoder.pending))
            empty!(decoder.pending)
            callback(mcp_decode(raw; maximum = decoder.maximum))
        end
        offset = newline + 1
    end
    nothing
end

function finish_mcp_lines!(callback::Function, decoder::MCPLineDecoder)
    isempty(decoder.pending) && return
    raw = String(copy(decoder.pending))
    empty!(decoder.pending)
    callback(mcp_decode(raw; maximum = decoder.maximum))
end

mutable struct MCPStdioTransport <: AbstractMCPTransport
    process::Base.Process
    process_id::Int
    input::Pipe
    output::Pipe
    error::Pipe
    diagnostics::OutputBuffer
    readers::Vector{Task}
    maximum::Int
    generation::Int
    callback::Function
    failed::Function
    closed::Bool
    write_mutex::ReentrantLock
    close_mutex::ReentrantLock
end

function mcp_bound_environment(spec::MCPServerSpec, lookup::Function)
    environment = Dict(key => ENV[key] for key in ("PATH", "SYSTEMROOT", "WINDIR", "LANG", "LC_ALL", "TMPDIR", "TEMP", "TMP") if haskey(ENV, key))
    for (name, source) in spec.environment_env
        value = lookup(source)
        value isa AbstractString && !occursin('\0', value) && ncodeunits(value) <= 65536 ||
            throw(ShenScopeError(:mcp_credentials, "Configured MCP environment value is invalid"))
        isempty(value) && throw(ShenScopeError(:mcp_credentials, "Configured MCP environment value is missing: " * source))
        environment[name] = value
    end
    environment
end

function mcp_stdio_transport(spec::MCPServerSpec, ctx::RuntimeContext, generation::Int,
        callback::Function, failed::Function; credential_lookup = key -> get(ENV, key, ""))
    directory = workspace_path(ctx.root, spec.cwd)
    isdir(directory) || throw(ShenScopeError(:mcp_config, "MCP process directory does not exist"))
    permission = canonical(Dict("argv" => spec.argv, "cwd" => directory, "environment_sources" => spec.environment_env))
    authorize!(ctx, :process, "mcp.process", permission; reason = "Start the configured MCP server process")
    environment = mcp_bound_environment(spec, credential_lookup)
    command = Sys.islinux() ? vcat(["setsid"], spec.argv) : spec.argv
    input = Pipe()
    output = Pipe()
    error = Pipe()
    process = try
        run(pipeline(ignorestatus(setenv(Cmd(Cmd(command); dir = directory), environment)); stdin = input, stdout = output, stderr = error); wait = false)
    catch
        for pipe in (input, output, error); isopen(pipe) && close(pipe); end
        throw(ShenScopeError(:mcp_transport, "Unable to start configured MCP command"))
    end
    close(input.out)
    close(output.in)
    close(error.in)
    process_id = try getpid(process) catch; 0; end
    transport = MCPStdioTransport(process, process_id, input, output, error, OutputBuffer(64 * 1024), Task[],
        spec.max_message_bytes, generation, callback, failed, false, ReentrantLock(), ReentrantLock())
    push!(transport.readers, @async begin
        decoder = MCPLineDecoder(transport.maximum)
        try
            while !eof(output) && !transport.closed
                feed_mcp_lines!(callback, decoder, readavailable(output))
                yield()
            end
            transport.closed || finish_mcp_lines!(callback, decoder)
            transport.closed || failed(:connection_closed)
        catch cause
            transport.closed || failed(cause isa ShenScopeError ? cause.code : :mcp_transport)
        end
    end)
    push!(transport.readers, @async begin
        try
            while !eof(error) && !transport.closed
                capture!(transport.diagnostics, readavailable(error))
                yield()
            end
        catch
            nothing
        end
    end)
    transport
end

function mcp_transport_send!(transport::MCPStdioTransport, message::AbstractDict,
        ctx::RuntimeContext; timeout = 30.0)
    text = mcp_encode(message, transport.maximum) * "\n"
    writer = @async lock(transport.write_mutex) do
        transport.closed && throw(ShenScopeError(:mcp_transport, "MCP transport is closed"))
        write(transport.input, text)
        flush(transport.input)
    end
    deadline = time() + timeout
    try
        while !istaskdone(writer)
            check_cancelled(ctx.cancellation)
            time() < deadline || throw(ShenScopeError(:mcp_timeout, "MCP send timed out"))
            sleep(0.01)
        end
        fetch(writer)
    catch cause
        mcp_transport_close!(transport)
        !istaskdone(writer) && try wait(writer) catch end
        cause isa ShenScopeError && rethrow()
        throw(ShenScopeError(:mcp_transport, "MCP command input is unavailable"))
    end
    nothing
end

function mcp_transport_close!(transport::MCPStdioTransport)
    lock(transport.close_mutex) do
        transport.closed && return
        transport.closed = true
        isopen(transport.input) && close(transport.input)
        if Sys.islinux() && transport.process_id > 0
            ccall(:kill, Cint, (Cint, Cint), -transport.process_id, 15)
        elseif !process_exited(transport.process)
            kill(transport.process, Base.SIGTERM)
        end
        deadline = time() + 0.25
        while !process_exited(transport.process) && time() < deadline; sleep(0.01); end
        if Sys.islinux() && transport.process_id > 0
            ccall(:kill, Cint, (Cint, Cint), -transport.process_id, 9)
        elseif !process_exited(transport.process)
            kill(transport.process, Base.SIGKILL)
        end
        try wait(transport.process) catch end
        for pipe in (transport.output, transport.error)
            isopen(pipe) && close(pipe)
        end
    end
    for task in transport.readers
        task === current_task() && continue
        try wait(task) catch end
    end
    nothing
end
