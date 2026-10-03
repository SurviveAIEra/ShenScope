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
            return String(copy(b.head)) * "\n… output omitted …\n" * String(copy(b.tail))
        end
        return String(vcat(b.head,b.tail))
    end
end

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
    "handle"=>string_schema(;max=128),"input"=>string_schema(),"close_input"=>Dict("type"=>"boolean"));required=["action"])

function terminate_process!(h::ProcessHandle)
    process_exited(h.process) && return
    if Sys.islinux()
        # setsid gives this process its own session/group; descendants share it.
        ccall(:kill,Cint,(Cint,Cint),-getpid(h.process),15)
    else
        kill(h.process,Base.SIGTERM)
    end
    finish=time()+0.25
    while !process_exited(h.process) && time()<finish;sleep(0.01);end
    if !process_exited(h.process)
        Sys.islinux() ? ccall(:kill,Cint,(Cint,Cint),-getpid(h.process),9) : kill(h.process,Base.SIGKILL)
    end
end

function start_process!(manager::ProcessManager,argv::Vector{String},ctx::RuntimeContext;
        cwd=ctx.root,timeout=120.0,output_limit=256*1024)
    isempty(argv) && throw(ShenScopeError(:arguments,"Empty command"))
    path=workspace_path(ctx.root,cwd)
    isdir(path) || throw(ShenScopeError(:path,"Process directory does not exist"))
    authorize!(ctx,:process,"process",canonical(argv);reason="Run workspace process")
    return lock(manager.mutex) do
        length(manager.handles)<manager.max_handles || throw(ShenScopeError(:process,"Process handle limit reached"))
        command=Sys.islinux() ? vcat(["setsid"],argv) : argv
        cmd=Cmd(Cmd(command);dir=path)
        # Keep an explicit inherited environment for compiler usability. Dynamic
        # analyzers use a separate restricted sandbox rather than this host tool.
        out=Pipe();err=Pipe();input=Pipe()
        process=run(pipeline(ignorestatus(cmd);stdin=input,stdout=out,stderr=err);wait=false)
        close(out.in);close(err.in);close(input.out)
        stdout=OutputBuffer(output_limit);stderr=OutputBuffer(output_limit)
        id=string(uuid4())
        readers=Task[]
        for (stream,buffer,label) in ((out,stdout,"stdout"),(err,stderr,"stderr"))
            push!(readers,@async begin
                try
                    while !eof(stream)
                        data=readavailable(stream)
                        capture!(buffer,data)
                        # The retained output is bounded; event chunks also are.
                        !isempty(data) && emit!(ctx,:process_output,Dict("handle"=>id,"stream"=>label,
                            "text"=>cliptext(transcode(String,data),64*1024)))
                    end
                finally
                    close(stream)
                end
            end)
        end
        h=ProcessHandle(id,ctx.session_id,argv,process,input,stdout,stderr,readers,time(),time()+timeout,
            ctx.cancellation,false,nothing)
        manager.handles[id]=h
        h.monitor=@async begin
            while !process_exited(process)
                if iscancelled(h.cancellation) || time()>h.deadline
                    h.timed_out=time()>h.deadline
                    terminate_process!(h);break
                end
                sleep(0.025)
            end
            wait(process)
            foreach(wait,readers)
            isopen(input) && close(input)
        end
        return h
    end
end

function process_status(h::ProcessHandle)
    exited=process_exited(h.process)
    exited && h.monitor!==nothing && wait(h.monitor)
    return Dict("handle"=>h.id,"running"=>!exited,"exit_code"=>exited ? h.process.exitcode : nothing,
        "stdout"=>output_text(h.stdout),"stderr"=>output_text(h.stderr),
        "stdout_bytes"=>h.stdout.total,"stderr_bytes"=>h.stderr.total,
        "timed_out"=>h.timed_out,"elapsed_seconds"=>time()-h.started)
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
        write(h.input,get(args,"input",""));flush(h.input)
        get(args,"close_input",false) && close(h.input)
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
