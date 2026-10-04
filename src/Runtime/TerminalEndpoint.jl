struct TerminalWindow
    rows::UInt16
    columns::UInt16
    width::UInt16
    height::UInt16
end

function terminal_open(size::TerminalSize)
    Sys.islinux() || throw(ShenScopeError(:terminal_platform,"PTY execution is not implemented on this platform"))
    master=Ref{Cint}(-1);slave=Ref{Cint}(-1)
    window=Ref(TerminalWindow(size.rows,size.columns,0,0))
    result=try
        ccall((:openpty,"libutil.so.1"),Cint,(Ref{Cint},Ref{Cint},Ptr{UInt8},Ptr{Cvoid},Ref{TerminalWindow}),
            master,slave,C_NULL,C_NULL,window)
    catch
        throw(ShenScopeError(:terminal_platform,"Linux PTY library is unavailable"))
    end
    result==0 || throw(ShenScopeError(:terminal_platform,"Unable to allocate a Linux pseudo-terminal"))
    try
        for fd in (master[],slave[])
            ccall(:fcntl,Cint,(Cint,Cint,Cint),fd,2,1)>=0 || error("descriptor inheritance unavailable")
        end
        flags=ccall(:fcntl,Cint,(Cint,Cint),master[],3)
        flags>=0 && ccall(:fcntl,Cint,(Cint,Cint,Cint),master[],4,flags|0x800)>=0 || error("nonblocking PTY unavailable")
        return TerminalEndpoint(master[],size,ReentrantLock()),Base.fdio(slave[],true)
    catch
        ccall(:close,Cint,(Cint,),master[]);ccall(:close,Cint,(Cint,),slave[])
        throw(ShenScopeError(:terminal_platform,"Unable to configure pseudo-terminal descriptors"))
    end
end

function terminal_close!(endpoint::TerminalEndpoint)
    lock(endpoint.mutex) do
        endpoint.descriptor<0 && return
        fd=endpoint.descriptor;endpoint.descriptor=-1
        ccall(:close,Cint,(Cint,),fd)
    end
    nothing
end

function terminal_read(endpoint::TerminalEndpoint;capacity=8192)
    lock(endpoint.mutex) do
        endpoint.descriptor>=0 || return (UInt8[],true)
        bytes=Vector{UInt8}(undef,capacity)
        count=GC.@preserve bytes ccall(:read,Clong,(Cint,Ptr{UInt8},Csize_t),endpoint.descriptor,pointer(bytes),capacity)
        if count>=0
            resize!(bytes,count);return (bytes,count==0)
        end
        errno=Base.Libc.errno()
        errno in (11,4) && return (UInt8[],false)
        errno in (5,9) && return (UInt8[],true)
        throw(ShenScopeError(:terminal_io,"Pseudo-terminal output is unavailable"))
    end
end

function terminal_write_some(endpoint::TerminalEndpoint,bytes::Vector{UInt8},offset::Int)
    lock(endpoint.mutex) do
        endpoint.descriptor>=0 || throw(ShenScopeError(:terminal_io,"Pseudo-terminal input is closed"))
        count=GC.@preserve bytes ccall(:write,Clong,(Cint,Ptr{UInt8},Csize_t),endpoint.descriptor,
            pointer(bytes,offset+1),length(bytes)-offset)
        count>=0 && return Int(count)
        Base.Libc.errno() in (11,4) && return 0
        throw(ShenScopeError(:terminal_io,"Pseudo-terminal input is unavailable"))
    end
end

function terminal_resize_endpoint!(endpoint::TerminalEndpoint,size::TerminalSize)
    lock(endpoint.mutex) do
        endpoint.descriptor>=0 || throw(ShenScopeError(:terminal_io,"Pseudo-terminal is closed"))
        window=Ref(TerminalWindow(size.rows,size.columns,0,0))
        ccall(:ioctl,Cint,(Cint,Culong,Ref{TerminalWindow}),endpoint.descriptor,0x5414,window)==0 ||
            throw(ShenScopeError(:terminal_io,"Unable to resize pseudo-terminal"))
        endpoint.size=size
    end
    terminal_size_view(size)
end
