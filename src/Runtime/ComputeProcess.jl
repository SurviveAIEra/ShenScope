function compute_child_environment()
    env = Dict{String,String}()
    for name in ("PATH", "JULIA_DEPOT_PATH")
        haskey(ENV, name) && (env[name] = ENV[name])
    end
    env["SHENSCOPE_ISOLATED_CHILD"] = "1"
    env["OPENBLAS_NUM_THREADS"] = "1"
    env["OMP_NUM_THREADS"] = "1"
    env["JULIA_NUM_GC_THREADS"] = "1"
    env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    env["JULIA_HISTORY"] = "/dev/null"
    env
end

function compute_child_command(limits::ComputeLimits)
    project = dirname(dirname(@__DIR__))
    python = Sys.which(get(ENV,"SHENSCOPE_COMPUTE_PYTHON","python3"))
    python !== nothing || throw(ShenScopeError(:sandbox,"Compute exec launcher requires Python 3"))
    launcher = joinpath(project,"scripts","backends","compute_launcher.py")
    isfile(launcher) || throw(ShenScopeError(:sandbox,"Compute exec launcher is unavailable"))
    encoded = canonical(compute_limits_dict(limits))
    # The expression contains only Core-owned limits, never caller code. Source
    # is delivered over stdin only after the trusted ready frame is validated.
    expression = "using ShenScope; ShenScope.compute_worker_main(ShenScope.compute_limits_from_dict(ShenScope.parsejson(" * repr(encoded) * ")))"
    vcat([String(python),"-I","-S",launcher],
        [first(Base.julia_cmd().exec), "--startup-file=no", "--history-file=no", "--compiled-modules=existing",
            "--threads=1", "--gcthreads=1", "--project=" * project, "-e", expression])
end

function compute_check_execution!(handle::ProcessHandle, ctx::RuntimeContext, target::String, limits::ComputeLimits)
    check_cancelled(ctx.cancellation)
    for category in (:read, :dynamic, :process)
        permission_target = category == :read ? ctx.root : target
        permission_decision(ctx.permissions, PermissionRequest("compute-current", category,
            "analysis.compute", permission_target, "Recheck isolated computation")) == Deny &&
            throw(ShenScopeError(:permission, "Isolated computation permission was revoked"))
    end
    lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
    end
    output_total = lock(handle.stdout.mutex) do; handle.stdout.total; end
    diagnostic_total = lock(handle.stderr.mutex) do; handle.stderr.total; end
    output_total <= handle.stdout.limit && diagnostic_total <= min(limits.output_bytes, 64 * 1024) ||
        throw(ShenScopeError(:capacity, "Isolated computation exceeded output capacity"))
    time() <= handle.deadline && !handle.timed_out || throw(ShenScopeError(:timeout, "Isolated computation timed out"))
    nothing
end

function compute_next_frame(handle::ProcessHandle, ctx::RuntimeContext, target::String,
        limits::ComputeLimits, offset::Int; maximum=limits.output_bytes)
    while true
        compute_check_execution!(handle, ctx, target, limits)
        bytes = output_bytes(handle.stdout)
        length(bytes) >= offset || throw(ShenScopeError(:compute_protocol, "Compute output cursor is invalid"))
        ending = findnext(==(UInt8('\n')), bytes, offset + 1)
        if ending !== nothing
            frame = bytes[offset+1:ending]
            length(frame) <= maximum || throw(ShenScopeError(:capacity, "Compute frame exceeds capacity"))
            # No untrusted bootstrap output is accepted before the handshake.
            value = compute_frame(String(frame), maximum)
            return (value=value, offset=ending)
        end
        length(bytes) - offset <= maximum || throw(ShenScopeError(:capacity, "Compute frame exceeds capacity"))
        if process_exited(handle.process)
            handle.monitor !== nothing && wait(handle.monitor)
            length(output_bytes(handle.stdout)) > length(bytes) && continue
            throw(ShenScopeError(:compute_protocol, "Compute process ended before a complete frame"))
        end
        sleep(0.01)
    end
end

function compute_deliver_input!(handle::ProcessHandle, payload::String, ctx::RuntimeContext,
        target::String, limits::ComputeLimits)
    writer = @async process_input!(handle, payload, ctx)
    try
        while !istaskdone(writer)
            compute_check_execution!(handle, ctx, target, limits)
            sleep(0.01)
        end
        fetch(writer)
    catch
        terminate_process!(handle)
        try wait(writer) catch end
        rethrow()
    end
end

function run_isolated_compute(ctx::RuntimeContext, source::AbstractString, inputs::AbstractVector;
        limits=ComputeLimits(), manager=ProcessManager(; max_handles=1))
    compute_seccomp_available() || throw(ShenScopeError(:sandbox, "Isolated Julia computation is unavailable on this platform"))
    code = compute_source(source, limits)
    1 <= length(inputs) <= limits.max_tests + 1 || throw(ShenScopeError(:arguments, "Compute input count exceeds capacity"))
    all(input -> input isa AbstractDict && Set(keys(input)) == Set(["data", "request"]) &&
        input["data"] isa AbstractDict && input["request"] isa AbstractDict, inputs) ||
        throw(ShenScopeError(:arguments, "Compute inputs must contain data and request dictionaries"))
    argv = compute_child_command(limits)
    launcher_hash = digest(read(argv[4],String))
    source_hash = digest(code)
    identifier = string(uuid4())
    request = Dict("protocol" => COMPUTE_PROTOCOL_VERSION, "id" => identifier, "source" => code,
        "source_sha256" => source_hash, "inputs" => deepcopy(inputs))
    payload = canonical(request) * "\n"
    ncodeunits(payload) <= limits.input_bytes || throw(ShenScopeError(:capacity, "Compute inputs exceed capacity"))
    bounded_json_object(payload; maximum=limits.input_bytes, max_depth=32, max_nodes=250_000, error_code=:arguments)
    target = canonical(Dict("source_sha256" => source_hash, "input_sha256" => digest(canonical(request["inputs"])),
        "launcher_sha256"=>launcher_hash,"limits" => compute_limits_dict(limits)))
    authorize!(ctx, :read, "analysis.compute", ctx.root; reason="Read explicit analyzer input data")
    authorize!(ctx, :dynamic, "analysis.compute", target; reason="Compile analyzer source in an isolated Julia child")
    handle = nothing
    started = time_ns()
    reservation = reserve!(ctx.budget, 0)
    try
        handle = start_process!(manager, argv, ctx; timeout=limits.wall_seconds,
            output_limit=limits.output_bytes + 16 * 1024 <= 4 * 1024^2 ? limits.output_bytes + 16 * 1024 : 4 * 1024^2,
            environment=compute_child_environment(), emit_output=false, permission_target=target,
            permission_tool="analysis.compute",before_start=()->begin
                compute_child_command(limits) == argv && digest(read(argv[4],String)) == launcher_hash ||
                    throw(ShenScopeError(:conflict,"Compute launcher changed after approval"))
            end)
        ready = compute_next_frame(handle, ctx, target, limits, 0; maximum=16 * 1024)
        sandbox = compute_ready_frame(ready.value, limits, handle.process_id)
        compute_check_execution!(handle, ctx, target, limits)
        emit!(ctx, :isolated_compute_ready, Dict("pid" => handle.process_id, "sandbox" => sandbox["backend"]))
        compute_deliver_input!(handle, payload, ctx, target, limits)
        result_frame = compute_next_frame(handle, ctx, target, limits, ready.offset)
        result = compute_result_frame(result_frame.value, identifier, source_hash, length(inputs))
        while !process_exited(handle.process)
            compute_check_execution!(handle, ctx, target, limits)
            sleep(0.01)
        end
        handle.monitor !== nothing && wait(handle.monitor)
        compute_check_execution!(handle, ctx, target, limits)
        handle.process.exitcode == 0 || throw(ShenScopeError(:compute_protocol, "Compute process exited unsuccessfully"))
        length(output_bytes(handle.stdout)) == result_frame.offset ||
            throw(ShenScopeError(:compute_protocol, "Compute process emitted trailing frames"))
        result["source_sha256"] = source_hash
        result["sandbox"] = sandbox
        result["limits"] = compute_limits_dict(limits)
        result["elapsed_seconds"] = (time_ns() - started) / 1e9
        emit!(ctx, :isolated_compute, Dict("source_sha256" => source_hash, "inputs" => length(inputs),
            "elapsed_seconds" => result["elapsed_seconds"], "sandbox" => sandbox["backend"]))
        result
    finally
        if handle !== nothing
            terminate_process!(handle)
            handle.monitor !== nothing && try wait(handle.monitor) catch end
            lock(manager.mutex) do; delete!(manager.handles, handle.id); end
        end
        release!(ctx.budget, reservation)
    end
end
