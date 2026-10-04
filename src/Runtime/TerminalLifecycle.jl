function terminal_bind!(manager::TerminalManager,ctx::RuntimeContext)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:terminal_closed,"Terminal manager is closed"))
        manager.root===nothing && (manager.root=ctx.root)
        manager.root==ctx.root || throw(ShenScopeError(:permission,"Terminal manager belongs to another workspace"))
    end
end

function terminal_owned(manager::TerminalManager,id::String,ctx::RuntimeContext)
    terminal_bind!(manager,ctx)
    lock(manager.mutex) do
        handle=get(manager.handles,id,nothing)
        handle===nothing && throw(ShenScopeError(:terminal,"Unknown terminal handle"))
        handle.owner==ctx.session_id && handle.root==ctx.root ||
            throw(ShenScopeError(:permission,"Terminal belongs to another conversation"))
        handle
    end
end

function terminal_permission_denied(handle::TerminalHandle)
    permission_decision(handle.context.permissions,PermissionRequest("terminal-active",:process,
        "terminal.start",handle.permission_target,"Current terminal process permission"))==Deny
end

function terminal_checkpoint(handle::TerminalHandle,ctx::RuntimeContext)
    handle.root==ctx.root && handle.owner==ctx.session_id || throw(ShenScopeError(:permission,"Terminal scope changed"))
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    terminal_permission_denied(handle) && throw(ShenScopeError(:permission,"Terminal process permission is denied"))
    time()<=handle.deadline || throw(ShenScopeError(:timeout,"Terminal lifetime expired"))
end

function terminal_terminate!(handle::TerminalHandle)
    first_termination=lock(handle.mutex) do
        handle.terminated && return false
        handle.terminated=true
        handle.phase in (:starting,:running) && (handle.phase=:closing)
        true
    end
    first_termination || return nothing
    pid=handle.process_id
    group=pid>0 && ccall(:kill,Cint,(Cint,Cint),-pid,0)==0
    group ? ccall(:kill,Cint,(Cint,Cint),-pid,15) :
        (!process_exited(handle.process) && try kill(handle.process,Base.SIGTERM) catch end)
    deadline=time()+0.25
    while time()<deadline
        alive=group ? ccall(:kill,Cint,(Cint,Cint),-pid,0)==0 : !process_exited(handle.process)
        !alive && break
        sleep(0.01)
    end
    group && ccall(:kill,Cint,(Cint,Cint),-pid,9)
    !process_exited(handle.process) && try kill(handle.process,Base.SIGKILL) catch end
    nothing
end

function terminal_emit_output!(handle::TerminalHandle,text::String;observed=0)
    first,last=terminal_append!(handle.journal,text;observed)
    isempty(text) && return
    permission_decision(handle.context.permissions,PermissionRequest("terminal-stream",:read,
        "terminal.output",handle.root,"Current terminal output permission"))==Deny && return
    emit!(handle.context,:terminal_output,Dict("handle"=>handle.id,"available_bytes"=>ncodeunits(text),
        "next_offset"=>last,"retained_from"=>first,"offset_unit"=>"filtered_utf8_bytes"))
end

function terminal_reader!(handle::TerminalHandle)
    filter=TerminalFilter();pending=UInt8[];ready=false
    expected=Vector{UInt8}(codeunits("SHENSCOPE_PTY_READY:"*handle.ready_nonce*"\r\n"))
    try
        while true
            bytes,ended=terminal_read(handle.endpoint)
            if !ready
                append!(pending,bytes)
                compared=min(length(pending),length(expected))
                pending[1:compared]==expected[1:compared] ||
                    throw(ShenScopeError(:terminal_start,"Terminal bootstrap receipt is invalid"))
                if length(pending)>=length(expected)
                    ready=true
                    lock(handle.mutex) do
                        handle.ready=true
                        handle.phase==:starting && (handle.phase=:running)
                    end
                    emit!(handle.context,:terminal_ready,Dict("handle"=>handle.id,"backend"=>"linux-openpty-v1"))
                    bytes=pending[length(expected)+1:end];empty!(pending)
                elseif ended
                    throw(ShenScopeError(:terminal_start,"Terminal bootstrap exited before controlling-terminal confirmation"))
                else
                    sleep(0.005);continue
                end
            end
            isempty(bytes) || terminal_emit_output!(handle,terminal_filter!(filter,bytes);observed=length(bytes))
            ended && break
            isempty(bytes) && sleep(0.005)
        end
    catch cause
        lock(handle.mutex) do
            handle.error=cause isa ShenScopeError ? cause.message : "Terminal output failed"
        end
        terminal_terminate!(handle)
    finally
        ready && terminal_emit_output!(handle,terminal_filter!(filter,UInt8[];final=true))
    end
end

function terminal_monitor!(handle::TerminalHandle)
    try
        startup_deadline=min(handle.deadline,handle.started+15)
        while !process_exited(handle.process)
            phase=lock(handle.mutex) do;handle.phase;end
            denied=terminal_permission_denied(handle)
            exhausted=try check_budget(handle.context.budget);false catch;true end
            timeout=time()>handle.deadline || phase==:starting && time()>startup_deadline
            if iscancelled(handle.context.cancellation) || denied || exhausted || timeout
                lock(handle.mutex) do
                    handle.timed_out=timeout;handle.permission_revoked=denied
                    phase==:starting && timeout && (handle.error="Terminal bootstrap confirmation timed out")
                end
                terminal_terminate!(handle);break
            end
            sleep(0.025)
        end
        wait(handle.process)
        # Close descendants retaining the slave; their output cannot hold shutdown open.
        terminal_terminate!(handle)
        deadline=time()+0.25
        while handle.reader!==nothing && !istaskdone(handle.reader) && time()<deadline;sleep(0.005);end
        terminal_close!(handle.endpoint)
        handle.reader!==nothing && try wait(handle.reader) catch end
    finally
        terminal_close!(handle.endpoint)
        lock(handle.mutex) do;handle.phase=handle.error===nothing ? :exited : :failed;end
        emit!(handle.context,:terminal_exited,Dict("handle"=>handle.id,"status"=>terminal_status(handle)))
    end
end

function terminal_status(handle::TerminalHandle)
    lock(handle.mutex) do
        exited=process_exited(handle.process)
        signal=exited ? Int(handle.process.termsignal) : nothing
        Dict("handle"=>handle.id,"phase"=>String(handle.phase),"running"=>!exited,
            "exit_code"=>exited ? (signal==0 ? handle.process.exitcode : -signal) : nothing,
            "signal"=>signal,"size"=>terminal_size_view(handle.endpoint.size),
            "timed_out"=>handle.timed_out,"permission_revoked"=>handle.permission_revoked,
            "error"=>handle.error,"elapsed_seconds"=>time()-handle.started,
            "backend"=>"linux-openpty-v1","sandbox"=>"host","merged_output"=>true,
            "controlling_terminal_confirmed"=>handle.ready)
    end
end

function terminal_start!(manager::TerminalManager,argv::Vector{String},ctx::RuntimeContext;
        cwd=ctx.root,timeout=120.0,size=TerminalSize(),retained_bytes=256*1024)
    terminal_bind!(manager,ctx)
    1<=length(argv)<=128 && all(x->!occursin('\0',x) && ncodeunits(x)<=65536,argv) ||
        throw(ShenScopeError(:arguments,"Invalid terminal argument vector"))
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05<=timeout<=3600 ||
        throw(ShenScopeError(:arguments,"Invalid terminal lifetime"))
    journal=TerminalJournal(retained_bytes)
    ctx.sandbox isa HostSandbox || throw(ShenScopeError(:terminal_sandbox,
        "PTY execution is not implemented for the selected restricted sandbox; no host fallback is allowed"))
    Sys.islinux() || throw(ShenScopeError(:terminal_platform,"PTY execution is not implemented on this platform"))
    path=workspace_path(ctx.root,cwd);isdir(path) || throw(ShenScopeError(:path,"Terminal directory does not exist"))
    target=canonical(Dict("argv"=>argv,"cwd"=>path,"size"=>terminal_size_view(size),"backend"=>"linux-openpty-v1"))
    authorize!(ctx,:read,"terminal.output",ctx.root;reason="Read output of the new terminal process")
    authorize!(ctx,:process,"terminal.start",target;reason="Start a host process with a controlling pseudo-terminal")
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    workspace_path(ctx.root,cwd)==path && isdir(path) || throw(ShenScopeError(:path,"Terminal directory changed after approval"))
    permission_decision(ctx.permissions,PermissionRequest("terminal-ready",:process,"terminal.start",target,"Recheck terminal launch"))==Deny &&
        throw(ShenScopeError(:permission,"Terminal launch is now denied"))
    duration=lock(ctx.budget.mutex) do
        remaining=ctx.budget.limits.max_seconds-(time_ns()-ctx.budget.started_ns)/1e9
        remaining>0 || throw(ShenScopeError(:budget,"Terminal wall-clock budget exhausted"))
        min(Float64(timeout),remaining)
    end
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:terminal_closed,"Terminal manager closed during approval"))
        length(manager.handles)<manager.max_handles || throw(ShenScopeError(:capacity,"Terminal handle limit reached; remove completed handles"))
        endpoint,slave=terminal_open(size)
        nonce=digest(string(uuid4())*string(uuid4()))
        worker=joinpath(@__DIR__,"TerminalWorker.jl")
        command=Cmd(Cmd(String[execution_julia_path(),"--startup-file=no","--history-file=no",
            "--compiled-modules=no","--threads=1","--gcthreads=1",worker,nonce,argv...]);dir=path)
        command=addenv(command,"TERM"=>"xterm-256color","COLORTERM"=>"truecolor")
        process=try
            run(pipeline(ignorestatus(command);stdin=slave,stdout=slave,stderr=slave);wait=false)
        catch
            terminal_close!(endpoint)
            throw(ShenScopeError(:terminal_start,"Unable to launch terminal bootstrap"))
        finally
            close(slave)
        end
        now=time()
        handle=TerminalHandle(string(uuid4()),ctx.session_id,ctx.root,copy(argv),path,process,getpid(process),
            endpoint,journal,ctx,target,:starting,now,now+duration,nonce,false,nothing,nothing,false,false,nothing,false,ReentrantLock())
        manager.handles[handle.id]=handle
        handle.reader=@async terminal_reader!(handle)
        handle.monitor=@async terminal_monitor!(handle)
        handle
    end
end

function terminal_wait_ready!(handle::TerminalHandle,ctx::RuntimeContext)
    try
        while lock(handle.mutex) do;!handle.ready && handle.phase in (:starting,:closing);end
            terminal_checkpoint(handle,ctx);sleep(0.01)
        end
        lock(handle.mutex) do;handle.ready;end || throw(ShenScopeError(:terminal_start,
            handle.error===nothing ? "Terminal bootstrap did not become ready" : handle.error))
    catch
        terminal_terminate!(handle);handle.monitor!==nothing && wait(handle.monitor);rethrow()
    end
    terminal_status(handle)
end

function cleanup_terminals!(manager::TerminalManager;owner=nothing,close_manager=false)
    handles=lock(manager.mutex) do
        close_manager && (manager.closed=true)
        [h for h in values(manager.handles) if owner===nothing || h.owner==owner]
    end
    close_manager && close_operations!(manager.operations)
    for handle in handles
        terminal_terminate!(handle)
        handle.monitor!==nothing && try wait(handle.monitor) catch end
        lock(manager.mutex) do;delete!(manager.handles,handle.id);end
    end
    nothing
end
