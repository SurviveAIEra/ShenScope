function terminal_write!(handle::TerminalHandle,text::AbstractString,ctx::RuntimeContext)
    ncodeunits(text)<=TERMINAL_MAX_INPUT || throw(ShenScopeError(:arguments,"Terminal input exceeds 64 KiB"))
    authorize!(ctx,:process,"terminal.write",handle.id;reason="Send input to this terminal process")
    bytes=Vector{UInt8}(codeunits(text));offset=0
    while offset<length(bytes)
        terminal_checkpoint(handle,ctx)
        process_exited(handle.process) && throw(ShenScopeError(:terminal_io,"Terminal process has exited"))
        permission_decision(ctx.permissions,PermissionRequest("terminal-write",:process,"terminal.write",handle.id,"Current terminal input permission"))==Deny &&
            throw(ShenScopeError(:permission,"Terminal input permission is denied"))
        wrote=terminal_write_some(handle.endpoint,bytes,offset);offset+=wrote
        wrote==0 && sleep(0.005)
    end
    Dict("handle"=>handle.id,"written_bytes"=>offset)
end

function terminal_resize!(handle::TerminalHandle,size::TerminalSize,ctx::RuntimeContext)
    authorize!(ctx,:process,"terminal.resize",handle.id;reason="Change terminal dimensions")
    terminal_checkpoint(handle,ctx)
    terminal_resize_endpoint!(handle.endpoint,size)
end

function terminal_interrupt!(handle::TerminalHandle,ctx::RuntimeContext)
    authorize!(ctx,:process,"terminal.interrupt",handle.id;reason="Interrupt the foreground terminal process group")
    terminal_checkpoint(handle,ctx)
    group=lock(handle.endpoint.mutex) do
        handle.endpoint.descriptor>=0 || throw(ShenScopeError(:terminal_io,"Terminal is closed"))
        ccall(:tcgetpgrp,Cint,(Cint,),handle.endpoint.descriptor)
    end
    group>0 && ccall(:getsid,Cint,(Cint,),group)==handle.process_id ||
        throw(ShenScopeError(:terminal_io,"Unable to verify the foreground terminal session"))
    ccall(:kill,Cint,(Cint,Cint),-group,2)==0 || throw(ShenScopeError(:terminal_io,"Unable to interrupt terminal foreground group"))
    Dict("handle"=>handle.id,"signal"=>"SIGINT","foreground_group_verified"=>true)
end

function terminal_remove!(manager::TerminalManager,id::String,ctx::RuntimeContext)
    handle=terminal_owned(manager,id,ctx)
    process_exited(handle.process) || throw(ShenScopeError(:terminal_busy,"Stop the terminal before removing its retained output"))
    handle.monitor!==nothing && wait(handle.monitor)
    lock(manager.mutex) do;delete!(manager.handles,id);end
    Dict("handle"=>id,"removed"=>true)
end

function terminal_list(manager::TerminalManager,ctx::RuntimeContext)
    terminal_bind!(manager,ctx)
    authorize!(ctx,:read,"terminal.inventory",ctx.root;reason="Read this conversation's terminal inventory")
    handles=lock(manager.mutex) do
        sort!([h for h in values(manager.handles) if h.owner==ctx.session_id];by=h->h.started)
    end
    Dict("terminals"=>terminal_status.(handles),"platform"=>terminal_platform_view(),"maximum_handles"=>manager.max_handles)
end
