function execution_landlock_status()
    if !(Sys.islinux() && Sys.WORD_SIZE==64 && Sys.ARCH in (:x86_64,:aarch64))
        return Dict("state"=>"unsupported_platform","abi"=>nothing,"enforced"=>false)
    end
    abi=ccall(:syscall,Clong,(Clong,Ptr{Cvoid},Csize_t,UInt32),444,C_NULL,0,1)
    failure=abi<0 ? Int(Base.Libc.errno()) : nothing
    Dict("state"=>abi>0 ? "kernel_interface_available" : "unavailable_in_current_process",
        "abi"=>abi>0 ? Int(abi) : nothing,"errno"=>failure,"enforced"=>false,
        "backend_implemented"=>false)
end

function execution_probe_view(probe::ExecutionProbe)
    Dict("backend"=>String(probe.backend),"state"=>String(probe.state),"reason"=>probe.reason,
        "checked_at"=>probe.checked_at,"elapsed_seconds"=>probe.elapsed_seconds,
        "executable_sha256"=>probe.executable_sha256,"exit_code"=>probe.exit_code,
        "os_isolation"=>false,"authority"=>"Diagnostic probe; every command prepares its own policy")
end

function execution_probe_command(ctx::RuntimeContext)
    policy=ExecutionPolicy(;limits=ExecutionLimits(;cpu_seconds=10))
    mounts=execution_runtime_mounts(policy,ctx)
    values=execution_environment(policy;source=Dict())
    nonce=digest(string(uuid4())*string(uuid4()))
    sha=digest(canonical(execution_policy_view(policy)))
    payload=execution_worker_arguments(policy,nonce,sha,["/usr/bin/true"])
    command=execution_bwrap_command(mounts,(),values,"/tmp",payload,:closed)
    command,"SHENSCOPE_EXEC_READY:"*nonce*":"*sha*":bubblewrap\n"
end

function execution_probe_backend(ctx::RuntimeContext;authorized=false)
    authorized || authorize!(ctx,:process,"security.probe","bubblewrap:read_only:closed";
        reason="Probe a private Linux namespace with no workspace mount and no networking")
    execution_checkpoint(ctx)
    started=time_ns();checked=utcstamp();fingerprint=nothing;manager=ProcessManager(;max_handles=1)
    try
        Sys.islinux() || return ExecutionProbe(:bubblewrap,:unsupported_platform,
            "Bubblewrap execution requires Linux",checked,0.0,nothing,nothing)
        compute_seccomp_available() || return ExecutionProbe(:bubblewrap,:blocked,
            "Required system-call policy library is unavailable",checked,0.0,nothing,nothing)
        executable=execution_bwrap_path()
        filesize(executable)<=16*1024^2 || throw(ShenScopeError(:sandbox,"Bubblewrap dependency is unexpectedly large"))
        fingerprint=bytes2hex(sha256(read(executable)))
        command,marker=execution_probe_command(ctx)
        internal=RuntimeContext(ctx.root;session_id=ctx.session_id,state_dir=ctx.state_dir,
            cancellation=ctx.cancellation,budget=ctx.budget,sandbox=HostSandbox(),
            permissions=PermissionPolicy(;rules=Dict(:process=>Allow)),sink=e->nothing)
        handle=start_process!(manager,command,internal;timeout=EXECUTION_PROBE_SECONDS,
            output_limit=EXECUTION_MAX_PROBE_BYTES,environment=Dict("PATH"=>"/usr/bin:/bin","LANG"=>"C.UTF-8"),emit_output=false)
        close(handle.input);wait(handle.monitor);status=process_status(handle)
        execution_checkpoint(ctx)
        if !authorized
            permission_decision(ctx.permissions,PermissionRequest("probe-publish",:process,"security.probe",
                "bubblewrap:read_only:closed","Confirm probe permission before publication"))==Deny &&
                throw(ShenScopeError(:permission,"Execution probe permission was revoked"))
        end
        success=status["exit_code"]==0 && startswith(status["stderr"],marker) && !status["timed_out"]
        reason=success ? "Namespace, worker restrictions and a bounded test command completed" :
            status["timed_out"] ? "Namespace probe exceeded its deadline" :
            isempty(strip(status["stderr"])) ? "Runner did not confirm isolation setup" :
            first(split(strip(status["stderr"]),'\n'))
        reason=join(Iterators.take(reason,512))
        state=success ? :available : status["exit_code"]==0 ? :unconfirmed : :blocked
        ExecutionProbe(:bubblewrap,state,reason,checked,(time_ns()-started)/1e9,fingerprint,status["exit_code"])
    catch cause
        cause isa ShenScopeError && cause.code in (:cancelled,:budget,:permission) && rethrow()
        reason=cause isa ShenScopeError ? cause.message : "Namespace probe could not complete"
        ExecutionProbe(:bubblewrap,:blocked,reason,checked,(time_ns()-started)/1e9,fingerprint,nothing)
    finally
        cleanup_processes!(manager,ctx.session_id)
    end
end

function execution_probe!(manager::ExecutionManager,ctx::RuntimeContext)
    lock(manager.mutex) do;manager.closed && throw(ShenScopeError(:security,"Execution manager is closed"));end
    probe=execution_probe_backend(ctx)
    key=digest(canonical(Dict("root"=>ctx.root,"state"=>ctx.state_dir,"session"=>ctx.session_id)))
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:security,"Execution manager closed before probe publication"))
        length(manager.probes)>=32 && !haskey(manager.probes,key) && empty!(manager.probes)
        manager.probes[key]=probe
    end
    execution_probe_view(probe)
end

function execution_status(manager::ExecutionManager,ctx::RuntimeContext)
    authorize!(ctx,:read,"security.status",ctx.root;reason="Read execution policy and capability metadata")
    key=digest(canonical(Dict("root"=>ctx.root,"state"=>ctx.state_dir,"session"=>ctx.session_id)))
    probe=lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:security,"Execution manager is closed"))
        get(manager.probes,key,nothing)
    end
    Dict("schema"=>1,"policy"=>execution_sandbox_view(ctx.sandbox),
        "bubblewrap_probe"=>probe===nothing ? nothing : execution_probe_view(probe),
        "landlock"=>execution_landlock_status(),"seccomp_library_available"=>compute_seccomp_available(),
        "automatic_host_fallback"=>false,"child_environment_values_disclosed"=>false,
        "limitations"=>["Host mode has no OS isolation","Probes are diagnostic and are not command receipts",
            "Installed/Windows/macOS backends are not verified","Workspace-write commands can change ordinary project files",
            "Runtime mounts are explicitly readable dependencies, not private data stores"])
end

function cleanup_execution!(manager::ExecutionManager)
    close_operations!(manager.operations)
    lock(manager.mutex) do;empty!(manager.probes);manager.closed=true;end
    nothing
end
