mutable struct OutputBuffer
    head::Vector{UInt8}
    tail::Vector{UInt8}
    total::Int
    limit::Int
    mutex::ReentrantLock
end
OutputBuffer(limit=256*1024)=OutputBuffer(UInt8[],UInt8[],0,limit,ReentrantLock())

function capture!(b::OutputBuffer,data::Vector{UInt8})
    lock(b.mutex) do
        b.total+=length(data)
        half=b.limit÷2
        n=min(length(data),max(0,half-length(b.head)))
        n>0 && append!(b.head,data[1:n])
        n<length(data) && append!(b.tail,data[n+1:end])
        length(b.tail)>half && deleteat!(b.tail,1:length(b.tail)-half)
    end
end
function output_text(b::OutputBuffer)
    lock(b.mutex) do
        retained=length(b.head)+length(b.tail)
        if b.total>retained
            # String(Vector{UInt8}) takes ownership of its input. A snapshot
            # must not consume the retained bytes or mutate future polls.
            return process_utf8(copy(b.head)) * "\n… output omitted …\n" * process_utf8(copy(b.tail))
        end
        return process_utf8(vcat(b.head,b.tail))
    end
end

function process_utf8(bytes::Vector{UInt8})
    text = String(bytes)
    isvalid(text) ? text : join(isvalid(character) ? string(character) : "�" for character in text)
end

output_bytes(b::OutputBuffer) = lock(b.mutex) do; vcat(b.head, b.tail); end

mutable struct ProcessHandle
    id::String
    owner::String
    command::Vector{String}
    process::Base.Process
    input::Pipe
    stdout::OutputBuffer
    stderr::OutputBuffer
    readers::Vector{Task}
    started::Float64
    deadline::Float64
    cancellation::CancellationToken
    timed_out::Bool
    monitor::Union{Nothing,Task}
    process_id::Int
    output::Pipe
    error::Pipe
    terminated::Bool
    termination_mutex::ReentrantLock
    execution::ExecutionEvidence
    permission_revoked::Bool
end

mutable struct ProcessManager
    handles::Dict{String,ProcessHandle}
    mutex::ReentrantLock
    max_handles::Int
end
ProcessManager(;max_handles=64)=ProcessManager(Dict{String,ProcessHandle}(),ReentrantLock(),max_handles)
struct ProcessTool <: AbstractTool
    manager::ProcessManager
end
ProcessTool()=ProcessTool(ProcessManager())
tool_name(::ProcessTool)="process"
tool_description(::ProcessTool)="Run argument-vector commands; start/poll/write/terminate session-owned background processes."
tool_schema(::ProcessTool)=object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["run","start","poll","write","terminate"]),
    "argv"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>128,"items"=>string_schema(;max=65536)),
    "cwd"=>string_schema(;max=4096),"timeout"=>Dict("type"=>"number","minimum"=>0.05,"maximum"=>3600),
    "handle"=>string_schema(;max=128),"input"=>string_schema(),"close_input"=>Dict("type"=>"boolean"),
    "purpose"=>Dict("type"=>"string","enum"=>["command","test"]));required=["action"])

function terminate_process!(h::ProcessHandle)
    lock(h.termination_mutex) do
        h.terminated && return
        h.terminated = true
        grouped = Sys.islinux() && h.process_id > 0
        group_alive = grouped && ccall(:kill, Cint, (Cint, Cint), -h.process_id, 0) == 0
        if group_alive
            ccall(:kill, Cint, (Cint, Cint), -h.process_id, 15)
        elseif !process_exited(h.process)
            try kill(h.process, Base.SIGTERM) catch end
        end
        deadline = time() + 0.25
        while time() < deadline
            alive = grouped ? ccall(:kill, Cint, (Cint, Cint), -h.process_id, 0) == 0 : !process_exited(h.process)
            !alive && process_exited(h.process) && break
            sleep(0.01)
        end
        # The leader may have exited while descendants still hold the pipes.
        grouped && ccall(:kill, Cint, (Cint, Cint), -h.process_id, 9)
        !process_exited(h.process) && try kill(h.process, Base.SIGKILL) catch end
        isopen(h.input) && try close(h.input) catch end
    end
    nothing
end

function start_process!(manager::ProcessManager,argv::Vector{String},ctx::RuntimeContext;
        cwd=ctx.root,timeout=120.0,output_limit=256*1024,environment=nothing,
        emit_output=true,permission_target=nothing,permission_tool="process",before_start=()->nothing)
    isempty(argv) && throw(ShenScopeError(:arguments,"Empty command"))
    length(argv) <= 128 && all(value -> !occursin('\0', value) && ncodeunits(value) <= 65536, argv) ||
        throw(ShenScopeError(:arguments, "Invalid process argument vector"))
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.01 <= timeout <= 3600 ||
        throw(ShenScopeError(:arguments, "Invalid process timeout"))
    output_limit isa Int && 64 <= output_limit <= 4 * 1024 * 1024 || throw(ShenScopeError(:arguments, "Invalid process output limit"))
    path=workspace_path(ctx.root,cwd)
    isdir(path) || throw(ShenScopeError(:path,"Process directory does not exist"))
    plan=execution_prepare(ctx.sandbox,argv,ctx;cwd=path,environment)
    target = permission_target === nothing ? canonical(Dict("argv" => argv, "cwd" => path)) : String(permission_target)
    plan!==nothing && (target=canonical(Dict("operation"=>target,"execution"=>execution_request_view(plan))))
    authorize!(ctx,:process,permission_tool,target;reason="Run workspace process")
    check_cancelled(ctx.cancellation)
    # Callers can revalidate a declaration after asynchronous approval.
    before_start()
    workspace_path(ctx.root, cwd) == path && isdir(path) || throw(ShenScopeError(:path, "Process directory changed after approval"))
    permission_decision(ctx.permissions, PermissionRequest("process-start", :process, String(permission_tool), target, "Recheck process launch")) == Deny &&
        throw(ShenScopeError(:permission, "Process launch is now denied"))
    plan!==nothing && execution_ready!(plan,ctx)
    permission_decision(ctx.permissions,PermissionRequest("process-ready",:process,String(permission_tool),target,"Confirm permission after execution preflight"))==Deny &&
        throw(ShenScopeError(:permission,"Process permission was revoked during preflight"))
    effective_timeout = lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
        remaining = ctx.budget.limits.max_seconds - (time_ns()-ctx.budget.started_ns)/1e9
        remaining > 0 || throw(ShenScopeError(:budget,"Process wall-clock budget exhausted"))
        min(Float64(timeout),remaining)
    end
    return lock(manager.mutex) do
        length(manager.handles)<manager.max_handles || throw(ShenScopeError(:process,"Process handle limit reached"))
        payload=plan===nothing ? argv : collect(plan.command)
        command=Sys.islinux() ? vcat(["setsid"],payload) : payload
        cmd=Cmd(Cmd(command);dir=path)
        # Keep an explicit inherited environment for compiler usability. Dynamic
        # analyzers use a separate restricted sandbox rather than this host tool.
        if plan!==nothing
            cmd=setenv(cmd,Dict("PATH"=>"/usr/bin:/bin","LANG"=>"C.UTF-8"))
        elseif environment!==nothing
            cmd=setenv(cmd,environment)
        end
        out=Pipe();err=Pipe();input=Pipe()
        process=try
            run(pipeline(ignorestatus(cmd);stdin=input,stdout=out,stderr=err);wait=false)
        catch
            for stream in (out, err, input); isopen(stream) && try close(stream) catch end; end
            throw(ShenScopeError(:process, "Unable to start workspace command"))
        end
        process_id = getpid(process)
        close(out.in);close(err.in);close(input.out)
        stdout=OutputBuffer(output_limit);stderr=OutputBuffer(output_limit)
        id=string(uuid4())
        evidence=plan===nothing ? ExecutionEvidence() : ExecutionEvidence(plan)
        readers=Task[]
        for (stream,buffer,label) in ((out,stdout,"stdout"),(err,stderr,"stderr"))
            push!(readers,@async begin
                decoder = UTF8StreamDecoder()
                try
                    while !eof(stream)
                        data = UInt8[read(stream, UInt8)]
                        available = min(bytesavailable(stream), 8191)
                        available > 0 && append!(data, read(stream, available))
                        label=="stderr" && (data=execution_stderr!(evidence,data))
                        isempty(data) && continue
                        capture!(buffer,data)
                        # The retained output is bounded; event chunks also are.
                        if emit_output
                            text = feed_utf8!(decoder, data)
                            isempty(text) || emit!(ctx,:process_output,Dict("handle"=>id,"stream"=>label,"text"=>text))
                        end
                    end
                catch cause
                    cause isa EOFError || !isopen(stream) || rethrow()
                finally
                    if label=="stderr"
                        remaining=execution_stderr!(evidence,UInt8[];final=true)
                        capture!(buffer,remaining)
                        text=feed_utf8!(decoder,remaining)
                        emit_output && !isempty(text) && emit!(ctx,:process_output,Dict("handle"=>id,"stream"=>label,"text"=>text))
                    end
                    final_text = finish_utf8!(decoder)
                    emit_output && !isempty(final_text) && emit!(ctx,:process_output,Dict("handle"=>id,"stream"=>label,"text"=>final_text))
                    close(stream)
                end
            end)
        end
        h=ProcessHandle(id,ctx.session_id,argv,process,input,stdout,stderr,readers,time(),time()+effective_timeout,
            ctx.cancellation,false,nothing,process_id,out,err,false,ReentrantLock(),evidence,false)
        manager.handles[id]=h
        h.monitor=@async begin
            while !process_exited(process)
                denied=permission_decision(ctx.permissions,PermissionRequest("process-active",:process,String(permission_tool),target,"Current process permission"))==Deny
                h.permission_revoked=denied || (plan!==nothing && execution_permission_denied(plan,ctx))
                if iscancelled(h.cancellation) || time()>h.deadline || h.permission_revoked
                    h.timed_out=time()>h.deadline
                    terminate_process!(h);break
                end
                sleep(0.025)
            end
            wait(process)
            drain_deadline = time() + 0.15
            while !all(istaskdone, readers) && time() < drain_deadline; sleep(0.01); end
            terminate_process!(h)
            for stream in (out, err); isopen(stream) && try close(stream) catch end; end
            for reader in readers; try wait(reader) catch end; end
            isopen(input) && close(input)
        end
        return h
    end
end

function process_status(h::ProcessHandle)
    exited=process_exited(h.process)
    exited && h.monitor!==nothing && wait(h.monitor)
    signal=exited ? Int(h.process.termsignal) : nothing
    return Dict("handle"=>h.id,"running"=>!exited,"exit_code"=>exited ? (signal==0 ? h.process.exitcode : -signal) : nothing,
        "signal"=>signal,
        "stdout"=>output_text(h.stdout),"stderr"=>output_text(h.stderr),
        "stdout_bytes"=>h.stdout.total,"stderr_bytes"=>h.stderr.total,
        "timed_out"=>h.timed_out,"elapsed_seconds"=>time()-h.started,
        "permission_revoked"=>h.permission_revoked,"sandbox"=>execution_evidence_view(h.execution;exited))
end

function process_input!(h::ProcessHandle, text::AbstractString, ctx::RuntimeContext; close_input=true, allow_closed_input=false)
    ncodeunits(text) <= 1024 * 1024 || throw(ShenScopeError(:arguments, "Process input exceeds capacity"))
    writer = @async begin
        try
            write(h.input, text); flush(h.input)
            true
        catch cause
            closed = cause isa Base.IOError && cause.code in (Base.UV_EPIPE,Base.UV_ECONNRESET,Base.UV_EBADF) ||
                cause isa ArgumentError && !isopen(h.input)
            allow_closed_input && closed || rethrow()
            false
        finally
            close_input && isopen(h.input) && close(h.input)
        end
    end
    written = try
        while !istaskdone(writer)
            check_cancelled(ctx.cancellation)
            time() < h.deadline || throw(ShenScopeError(:timeout, "Process input timed out"))
            sleep(0.01)
        end
        fetch(writer)
    catch cause
        terminate_process!(h)
        try wait(writer) catch end
        cause isa ShenScopeError && rethrow()
        throw(ShenScopeError(:process, "Process input is unavailable"))
    end
    check_cancelled(ctx.cancellation)
    written
end

function owned_handle(manager::ProcessManager,id::String,ctx::RuntimeContext)
    lock(manager.mutex) do
        h=get(manager.handles,id,nothing)
        h===nothing && throw(ShenScopeError(:process,"Unknown process handle"))
        h.owner==ctx.session_id || throw(ShenScopeError(:permission,"Process belongs to another session"))
        return h
    end
end

function execute(t::ProcessTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    if action in ("run","start")
        haskey(args,"argv") || throw(ShenScopeError(:arguments,"Command argv required"))
        h=start_process!(t.manager,String.(args["argv"]),ctx;cwd=get(args,"cwd",ctx.root),timeout=get(args,"timeout",120.0))
        if action=="run"
            try
                close(h.input);wait(h.monitor)
                return process_status(h)
            finally
                lock(t.manager.mutex) do;delete!(t.manager.handles,h.id);end
            end
        end
        return process_status(h)
    end
    haskey(args,"handle") || throw(ShenScopeError(:arguments,"Process handle required"))
    h=owned_handle(t.manager,args["handle"],ctx)
    if action=="write"
        authorize!(ctx,:process,"process.write",h.id)
        process_exited(h.process) && throw(ShenScopeError(:process,"Process has exited"))
        process_input!(h,get(args,"input",""),ctx;close_input=get(args,"close_input",false))
    elseif action=="terminate"
        terminate_process!(h);wait(h.monitor)
    end
    return process_status(h)
end

function cleanup_processes!(manager::ProcessManager,owner::String)
    handles=lock(manager.mutex) do
        [h for h in values(manager.handles) if h.owner==owner]
    end
    for h in handles
        terminate_process!(h);wait(h.monitor)
        lock(manager.mutex) do;delete!(manager.handles,h.id);end
    end
end

struct GitTool <: AbstractTool
    process::ProcessTool
end
GitTool()=GitTool(ProcessTool())
tool_name(::GitTool)="git"
tool_description(::GitTool)="Read Git status, diff, or bounded log for review."
execution_mode(::GitTool)=:parallel
tool_schema(::GitTool)=object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["status","diff","log"])))
function execute(t::GitTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    argv=action=="status" ? ["git","status","--short"] : action=="diff" ?
        ["git","diff","--no-ext-diff","--no-textconv"] : ["git","log","-20","--format=%h %s"]
    return execute(t.process,Dict("action"=>"run","argv"=>argv,"timeout"=>30),ctx)
end
