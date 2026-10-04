module ExecutionWorker

const LIBRARY="libseccomp.so.2"
const ALLOW=UInt32(0x7fff0000)
const DENY=UInt32(0x0005000d)
struct ResourceLimit
    soft::UInt64
    hard::UInt64
end
struct Comparison
    argument::UInt32
    operation::UInt32
    value::UInt64
    extra::UInt64
end

function set_limit(resource::Int,value::Int)
    limit=Ref(ResourceLimit(UInt64(value),UInt64(value)))
    ccall(:setrlimit,Cint,(Cint,Ref{ResourceLimit}),resource,limit)==0 || error("resource limit unavailable")
end

function syscall_number(name::String)
    ccall((:seccomp_syscall_resolve_name,LIBRARY),Cint,(Cstring,),name)
end

function deny_syscall(filter,name;comparisons=Comparison[],required=false,action=DENY)
    number=syscall_number(name)
    number>=0 || (required ? error("required system call unavailable") : return false)
    result=GC.@preserve comparisons ccall((:seccomp_rule_add_array,LIBRARY),Cint,
        (Ptr{Cvoid},UInt32,Cint,UInt32,Ptr{Comparison}),filter,action,number,
        UInt32(length(comparisons)),isempty(comparisons) ? C_NULL : pointer(comparisons))
    result==0 || error("system call policy construction failed")
    true
end

function install_filter(network::String)
    network in ("closed","open") || error("invalid network policy")
    ccall(:prctl,Cint,(Cint,Culong,Culong,Culong,Culong),38,1,0,0,0)==0 || error("no_new_privs unavailable")
    filter=ccall((:seccomp_init,LIBRARY),Ptr{Cvoid},(UInt32,),ALLOW)
    filter!=C_NULL || error("system call filter unavailable")
    try
        for name in ("ptrace","process_vm_readv","process_vm_writev","pidfd_getfd",
                "mount","umount2","pivot_root","chroot","open_by_handle_at","name_to_handle_at",
                "setns","unshare","bpf","io_uring_setup","io_uring_enter","io_uring_register",
                "init_module","finit_module","delete_module","kexec_load","kexec_file_load",
                "reboot","swapon","swapoff","userfaultfd","perf_event_open")
            deny_syscall(filter,name)
        end
        # ENOSYS permits native runtimes to fall back to the auditable clone ABI.
        deny_syscall(filter,"clone3";action=UInt32(0x00050026))
        for flag in (0x00020000,0x02000000,0x04000000,0x08000000,0x10000000,0x20000000,0x40000000)
            deny_syscall(filter,"clone";comparisons=[Comparison(0,7,UInt64(flag),UInt64(flag))])
        end
        if network=="closed"
            for name in ("socket","socketpair","connect","bind","listen","accept","accept4",
                    "sendto","sendmsg","sendmmsg","recvfrom","recvmsg","recvmmsg")
                deny_syscall(filter,name;required=name in ("socket","connect"))
            end
        else
            for family in (16,40)
                deny_syscall(filter,"socket";comparisons=[Comparison(0,4,UInt64(family),0)],required=true)
            end
        end
        ccall((:seccomp_load,LIBRARY),Cint,(Ptr{Cvoid},),filter)==0 || error("system call filter installation failed")
    finally
        ccall((:seccomp_release,LIBRARY),Cvoid,(Ptr{Cvoid},),filter)
    end
    nothing
end

function raw_stderr(text::String)
    bytes=Vector{UInt8}(codeunits(text));offset=0
    while offset<length(bytes)
        wrote=GC.@preserve bytes ccall(:write,Clong,(Cint,Ptr{UInt8},Csize_t),2,pointer(bytes,offset+1),length(bytes)-offset)
        wrote>0 || return
        offset+=wrote
    end
end

function run(args::Vector{String})
    length(args)>=10 && args[9]=="--" || error("invalid worker arguments")
    nonce,policy,network=args[1:3]
    occursin(r"^[0-9a-f]{64}$",nonce) && occursin(r"^[0-9a-f]{64}$",policy) || error("invalid worker identity")
    values=parse.(Int,args[4:7]);cpu,file_bytes,open_files,address_space=values
    1<=cpu<=3600 && 1024<=file_bytes<=1024^3 && 32<=open_files<=4096 &&
        (address_space==0 || 512*1024^2<=address_space<=64*1024^3) || error("invalid worker limits")
    args[8]=="bubblewrap" || args[8]=="network_probe" || error("invalid worker backend")
    target=args[10:end];all(value->!occursin('\0',value),target) || error("invalid worker argv")
    pointers=Ptr{UInt8}[pointer(value) for value in target];push!(pointers,C_NULL)
    # Build all Julia data before closing runtime descriptors and entering policy.
    set_limit(0,cpu);set_limit(1,file_bytes);set_limit(4,0);set_limit(7,open_files)
    address_space>0 && set_limit(9,address_space)
    install_filter(network)
    # Only the three dedicated parent pipes survive into the command.
    result=ccall(:syscall,Clong,(Clong,UInt32,UInt32,UInt32),436,3,typemax(UInt32),0)
    result==0 || error("descriptor closure unavailable")
    raw_stderr("SHENSCOPE_EXEC_READY:"*nonce*":"*policy*":"*args[8]*"\n")
    GC.@preserve target pointers ccall(:execvp,Cint,(Cstring,Ptr{Ptr{UInt8}}),target[1],pointer(pointers))
    raw_stderr("ShenScope command executable could not start.\n")
    ccall(:_exit,Cvoid,(Cint,),126)
end

end

if abspath(PROGRAM_FILE)==@__FILE__
    try
        ExecutionWorker.run(ARGS)
    catch
        ExecutionWorker.raw_stderr("ShenScope isolation setup failed before command execution.\n")
        ccall(:_exit,Cvoid,(Cint,),125)
    end
end
