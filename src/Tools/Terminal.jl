struct TerminalTool <: AbstractTool
    manager::TerminalManager
end
TerminalTool()=TerminalTool(TerminalManager())
tool_name(::TerminalTool)="terminal"
tool_description(::TerminalTool)="Start session-owned argument-vector PTY processes; inspect bounded UTF-8 cursor output, send input, resize, interrupt, stop and remove."
tool_schema(::TerminalTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["platform","list","start","poll","write","resize","interrupt","stop","remove"]),
    "argv"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>128,"items"=>string_schema(;max=65536)),
    "cwd"=>string_schema(;max=4096),"handle"=>string_schema(;max=128),
    "timeout"=>Dict("type"=>"number","minimum"=>0.05,"maximum"=>3600),
    "rows"=>Dict("type"=>"integer","minimum"=>2,"maximum"=>500),
    "columns"=>Dict("type"=>"integer","minimum"=>2,"maximum"=>500),
    "retained_bytes"=>Dict("type"=>"integer","minimum"=>1024,"maximum"=>TERMINAL_MAX_RETAINED),
    "input"=>string_schema(;max=TERMINAL_MAX_INPUT),
    "offset"=>Dict("type"=>"integer","minimum"=>0),
    "max_bytes"=>Dict("type"=>"integer","minimum"=>4,"maximum"=>TERMINAL_MAX_PAGE),
    "format"=>Dict("type"=>"string","enum"=>["terminal","plain"]));required=["action"])

function execute(tool::TerminalTool,args::AbstractDict,ctx::RuntimeContext)
    action=args["action"]
    action=="platform" && return terminal_platform_view()
    action=="list" && return terminal_list(tool.manager,ctx)
    if action=="start"
        haskey(args,"argv") || throw(ShenScopeError(:arguments,"Terminal argv is required"))
        handle=terminal_start!(tool.manager,String.(args["argv"]),ctx;cwd=get(args,"cwd",ctx.root),
            timeout=get(args,"timeout",120.0),size=TerminalSize(get(args,"rows",24),get(args,"columns",80)),
            retained_bytes=get(args,"retained_bytes",256*1024))
        return terminal_wait_ready!(handle,ctx)
    end
    haskey(args,"handle") || throw(ShenScopeError(:arguments,"Terminal handle is required"))
    handle=terminal_owned(tool.manager,String(args["handle"]),ctx)
    if action=="poll"
        authorize!(ctx,:read,"terminal.output",handle.id;reason="Read retained terminal process output")
        page=terminal_page(handle.journal;offset=get(args,"offset",0),max_bytes=get(args,"max_bytes",TERMINAL_MAX_PAGE))
        get(args,"format","plain")=="plain" && (page["text"]=terminal_plain_text(page["text"]))
        return merge(terminal_status(handle),Dict("output"=>page))
    elseif action=="write"
        return terminal_write!(handle,get(args,"input",""),ctx)
    elseif action=="resize"
        return terminal_resize!(handle,TerminalSize(get(args,"rows",24),get(args,"columns",80)),ctx)
    elseif action=="interrupt"
        return terminal_interrupt!(handle,ctx)
    elseif action=="stop"
        authorize!(ctx,:process,"terminal.stop",handle.id;reason="Stop this terminal and its owned process group")
        terminal_terminate!(handle);handle.monitor!==nothing && wait(handle.monitor)
        return terminal_status(handle)
    elseif action=="remove"
        return terminal_remove!(tool.manager,handle.id,ctx)
    end
    throw(ShenScopeError(:arguments,"Unknown terminal action"))
end
