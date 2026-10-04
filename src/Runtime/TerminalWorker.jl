module TerminalWorker
function main(arguments::Vector{String})
    length(arguments)>=2 || ccall(:_exit,Cvoid,(Cint,),126)
    nonce=arguments[1]
    occursin(r"^[0-9a-f]{64}$",nonce) || ccall(:_exit,Cvoid,(Cint,),126)
    target=arguments[2:end]
    all(x->!occursin('\0',x),target) || ccall(:_exit,Cvoid,(Cint,),126)
    parent=ccall(:getppid,Cint,())
    ccall(:prctl,Cint,(Cint,Culong,Culong,Culong,Culong),1,15,0,0,0)==0 || ccall(:_exit,Cvoid,(Cint,),126)
    ccall(:getppid,Cint,())==parent || ccall(:_exit,Cvoid,(Cint,),126)
    ccall(:setsid,Cint,())>=0 || ccall(:_exit,Cvoid,(Cint,),126)
    ccall(:ioctl,Cint,(Cint,Culong,Cint),0,0x540e,0)==0 || ccall(:_exit,Cvoid,(Cint,),126)
    ccall(:isatty,Cint,(Cint,),0)==1 && ccall(:tcgetpgrp,Cint,(Cint,),0)==ccall(:getpgrp,Cint,()) ||
        ccall(:_exit,Cvoid,(Cint,),126)
    pointers=Ptr{UInt8}[pointer(value) for value in target];push!(pointers,C_NULL)
    receipt=Vector{UInt8}(codeunits("SHENSCOPE_PTY_READY:"*nonce*"\n"))
    mask=zeros(UInt8,128)
    ccall(:syscall,Clong,(Clong,UInt32,UInt32,UInt32),436,3,typemax(UInt32),0)==0 ||
        ccall(:_exit,Cvoid,(Cint,),126)
    # Ignored dispositions survive exec; restore terminal/job-control signals
    # inherited from a noninteractive Julia parent before starting the payload.
    for signal in (1,2,3,13,15,20,21,22)
        ccall(:signal,Ptr{Cvoid},(Cint,Ptr{Cvoid}),signal,C_NULL)
    end
    GC.@preserve mask ccall(:sigprocmask,Cint,(Cint,Ptr{UInt8},Ptr{Cvoid}),2,pointer(mask),C_NULL)==0 ||
        ccall(:_exit,Cvoid,(Cint,),126)
    GC.@preserve receipt ccall(:write,Clong,(Cint,Ptr{UInt8},Csize_t),1,pointer(receipt),length(receipt))
    GC.@preserve target pointers ccall(:execvp,Cint,(Cstring,Ptr{Ptr{UInt8}}),target[1],pointer(pointers))
    ccall(:_exit,Cvoid,(Cint,),127)
end
end
if abspath(PROGRAM_FILE)==@__FILE__
    try
        TerminalWorker.main(ARGS)
    catch
        ccall(:_exit,Cvoid,(Cint,),126)
    end
end
