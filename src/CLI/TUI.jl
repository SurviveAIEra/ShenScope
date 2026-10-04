mutable struct TerminalState
    lines::Vector{String}
    draft::Vector{Char}
    offset::Int
    status::String
    active::Bool
    quitting::Bool
    dirty::Bool
    approval::Union{Nothing,PermissionRequest}
    decision::Union{Nothing,Channel{Symbol}}
    escape::String
end
TerminalState()=TerminalState(String[],Char[],0,"Ready",false,false,true,nothing,nothing,"")

function terminal_safe(text::AbstractString)
    cleaned=replace(String(text),r"\e(?:\][^\a\e]*(?:\a|\e\\)|[PX^_].*?\e\\|\[[0-?]*[ -/]*[@-~]|.)"s=>"")
    return replace(cleaned,r"[\x00-\x08\x0b-\x1f\x7f]"=>"")
end

function terminal_push!(state::TerminalState,text::AbstractString;append=false)
    safe=terminal_safe(cliptext(text,32768))
    if append && !isempty(state.lines)
        state.lines[end]=cliptext(state.lines[end]*safe,32768)
    else
        push!(state.lines,safe)
    end
    length(state.lines)>500 && deleteat!(state.lines,1:length(state.lines)-500)
    state.dirty=true
end

function terminal_event!(state::TerminalState,event::AgentEvent)
    kind=event.kind;payload=event.payload
    if kind==:text_delta
        terminal_push!(state,payload["text"];append=true)
    elseif kind==:model_request
        terminal_push!(state,"\nAssistant: ")
    elseif kind==:tool_started
        terminal_push!(state,"Tool: "*payload["name"])
    elseif kind==:tool_completed
        terminal_push!(state,canonical(payload))
    elseif kind==:session_completed
        state.status="Complete";state.active=false;state.dirty=true
    elseif kind==:session_error
        state.status=payload["message"];state.active=false;state.dirty=true
    elseif kind==:file_changed
        terminal_push!(state,"Changed: "*get(payload,"path",""))
    elseif kind==:context_prepared
        state.status="Context: "*string(payload["measure"]["estimated_tokens"])*" estimated input tokens";state.dirty=true
    elseif kind==:context_compacted
        terminal_push!(state,"Context checkpoint saved; original messages remain available.")
    elseif kind==:context_recovery
        state.status="Reducing context after model input limit";state.dirty=true
    end
end

function terminal_crop(text::AbstractString,width::Int)
    io=IOBuffer();used=0
    for char in text
        cell=textwidth(char)
        used+cell>width && break
        write(io,char);used+=cell
    end
    return String(take!(io))
end

function terminal_frame(state::TerminalState,ctx::RuntimeContext,rows::Int,columns::Int)
    rows=max(rows,8);columns=max(columns,24)
    output=String["ShenScope · "*state.status,"Session "*ctx.session_id]
    visible=String[]
    for text in state.lines, line in split(text,'\n';keepempty=true)
        # Cropping keeps a bounded redraw even for large tool results. Full
        # evidence remains in the session and archived tool outputs.
        push!(visible,terminal_crop(line,columns))
    end
    capacity=rows-6
    finish=max(0,length(visible)-state.offset)
    start=max(1,finish-capacity+1)
    append!(output,finish>=start ? visible[start:finish] : String[])
    while length(output)<rows-4;push!(output,"");end
    budget=budget_status(ctx.budget)
    push!(output,"Steps $(budget["steps"]) · Tokens $(budget["tokens"]) · Cost \$$(round(budget["cost"];digits=4))")
    if state.approval!==nothing
        push!(output,"Approve $(state.approval.category): $(terminal_safe(state.approval.target))")
        push!(output,"a: once   s: session   d: deny")
    else
        push!(output,"Enter: send/steer · Ctrl-C: cancel · Ctrl-D: exit · ↑/↓: scroll")
        push!(output,"> "*String(copy(state.draft)))
    end
    return join(terminal_crop.(terminal_safe.(output),columns),"\e[K\r\n")*"\e[K"
end

function terminal_key!(state::TerminalState,char::Char)
    state.dirty=true
    if state.approval!==nothing
        if char in ('a','s','d')
            put!(state.decision,char=='a' ? :once : char=='s' ? :session : :deny)
            state.approval=nothing;state.decision=nothing
        elseif char=='\x03'
            return :cancel
        end
        return :none
    end
    if !isempty(state.escape)
        state.escape*=string(char)
        if state.escape=="\e[A";state.offset+=3;state.escape="";
        elseif state.escape=="\e[B";state.offset=max(0,state.offset-3);state.escape="";
        elseif length(state.escape)>=3;state.escape="";
        end
        return :none
    end
    char=='\e' && (state.escape="\e";return :none)
    char=='\x03' && return :cancel
    char=='\x04' && return :quit
    char in ('\r','\n') && return :send
    if char in ('\x7f','\b')
        !isempty(state.draft) && pop!(state.draft)
    elseif !iscntrl(char) && length(state.draft)<16384
        push!(state.draft,char)
    end
    return :none
end

function terminal_decode!(pending::Vector{UInt8},bytes::Vector{UInt8})
    append!(pending,bytes);characters=Char[];offset=1
    while offset<=length(pending)
        firstbyte=pending[offset]
        count=firstbyte<0x80 ? 1 : leading_ones(firstbyte)
        if !(count in 1:4)
            push!(characters,'\ufffd');offset+=1;continue
        end
        offset+count-1<=length(pending) || break
        text=String(pending[offset:offset+count-1])
        push!(characters,isvalid(text) && length(text)==1 ? only(text) : '\ufffd')
        offset+=count
    end
    offset>1 && deleteat!(pending,1:offset-1)
    return characters
end

function run_tui(provider::AbstractModelProvider,ctx::RuntimeContext,session::Session;input=stdin,output=stdout,tools=core_tools())
    input isa Base.TTY && output isa Base.TTY || throw(ShenScopeError(:terminal,"TUI requires an interactive terminal"))
    state=TerminalState();control=AgentControl();job=nothing
    old_sink=ctx.sink;old_approval=ctx.approve
    ctx.sink=e->terminal_event!(state,e)
    ctx.approve=r->begin
        state.approval=r;state.decision=Channel{Symbol}(1);state.dirty=true
        channel=state.decision
        while !isready(channel)
            (state.quitting || iscancelled(ctx.cancellation)) && return :deny
            sleep(0.025)
        end
        return take!(channel)
    end
    terminal=REPL.Terminals.TTYTerminal(get(ENV,"TERM","xterm"),input,output,stderr)
    REPL.Terminals.raw!(terminal,true) || throw(ShenScopeError(:terminal,"Cannot enable terminal raw mode"))
    # Decode bounded available bytes without waiting for another key, keeping
    # redraw, cancellation and approval handling on the same UI task.
    pending=UInt8[]
    Base.start_reading(input)
    try
        write(output,"\e[?1049h\e[?25l")
        for message in session.messages
            message.role in (:user,:assistant) && terminal_push!(state,string(message.role)*": "*message.text)
        end
        while !state.quitting
            Base.start_reading(input)
            available=min(bytesavailable(input),65536)
            keys=available>0 ? terminal_decode!(pending,read(input,available)) : Char[]
            for char in keys
                action=terminal_key!(state,char)
                if action==:quit
                    state.quitting=true;cancel!(ctx.cancellation)
                elseif action==:cancel
                    state.active && cancel!(ctx.cancellation)
                    state.status=state.active ? "Cancelling…" : "Ready"
                elseif action==:send
                    prompt=strip(String(copy(state.draft)));empty!(state.draft)
                    isempty(prompt) && continue
                    if prompt=="/quit";state.quitting=true;cancel!(ctx.cancellation);continue;end
                    if state.active
                        steer!(control,prompt);terminal_push!(state,"Steering: "*prompt)
                    else
                        ctx.cancellation=CancellationToken();state.active=true;state.status="Running…";state.offset=0
                        terminal_push!(state,"User: "*prompt)
                        job=@async try
                            run_agent!(provider,prompt,ctx;session,tools,control)
                        catch e
                            state.status=e isa ShenScopeError ? e.message : "Task failed"
                        finally
                            state.active=false;state.dirty=true;state.approval=nothing;state.decision=nothing
                        end
                        yield()
                    end
                end
            end
            !isopen(input) && (state.quitting=true;cancel!(ctx.cancellation))
            if state.dirty
                # Writes can yield to the agent. Clear before writing so an
                # event delivered during flush retains its redraw request.
                state.dirty=false
                rows,columns=displaysize(output)
                write(output,"\e[H",terminal_frame(state,ctx,rows,columns));flush(output)
            end
            sleep(0.05)
        end
    finally
        state.quitting=true;cancel!(ctx.cancellation)
        job!==nothing && wait(job)
        for tool in tools;tool isa ProcessTool && cleanup_processes!(tool.manager,ctx.session_id);end
        for tool in tools;tool isa MCPControlTool && cleanup_mcp!(tool.manager);end
        for tool in tools;tool isa SkillsTool && cleanup_skills!(tool.manager);end
        for tool in tools;tool isa HooksTool && cleanup_hooks!(tool.manager);end
        for tool in tools;tool isa ContextTool && cleanup_context!(tool.manager);end
        for tool in tools;tool isa AnalyzersTool && cleanup_analyzers!(tool.manager);end
        for tool in tools;tool isa ModelsTool && cleanup_model_catalogs!(tool.manager);end
        REPL.Terminals.raw!(terminal,false)
        write(output,"\e[?25h\e[?1049l");flush(output)
        ctx.sink=old_sink;ctx.approve=old_approval
        Base.stop_reading(input)
    end
    return 0
end
