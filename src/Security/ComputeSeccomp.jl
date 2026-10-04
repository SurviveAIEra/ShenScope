const COMPUTE_SECCOMP_LIBRARY = "libseccomp.so.2"
const COMPUTE_SCMP_ALLOW = UInt32(0x7fff0000)
const COMPUTE_SCMP_DENY = UInt32(0x0005000d)

struct ComputeSyscallComparison
    argument::UInt32
    operation::UInt32
    value::UInt64
    mask_value::UInt64
end

compute_arg_equal(index, value) = ComputeSyscallComparison(UInt32(index), UInt32(4), UInt64(value), UInt64(0))
compute_arg_mask(index, mask, value) = ComputeSyscallComparison(UInt32(index), UInt32(7), UInt64(mask), UInt64(value))

function compute_syscall_number(name::String)
    ccall((:seccomp_syscall_resolve_name, COMPUTE_SECCOMP_LIBRARY), Cint, (Cstring,), name)
end

function compute_allow_syscall(filter::Ptr{Cvoid}, name::String,
        comparisons::Vector{ComputeSyscallComparison}=ComputeSyscallComparison[]; required=false)
    number = compute_syscall_number(name)
    if number < 0
        required && throw(ShenScopeError(:sandbox, "Required compute system call is unavailable"))
        return false
    end
    result = GC.@preserve comparisons ccall((:seccomp_rule_add_array, COMPUTE_SECCOMP_LIBRARY),
        Cint, (Ptr{Cvoid}, UInt32, Cint, UInt32, Ptr{ComputeSyscallComparison}),
        filter, COMPUTE_SCMP_ALLOW, number, UInt32(length(comparisons)),
        isempty(comparisons) ? C_NULL : pointer(comparisons))
    result == 0 || throw(ShenScopeError(:sandbox, "Unable to construct compute system-call rule"))
    true
end

function compute_seccomp_available()
    Sys.islinux() && Sys.WORD_SIZE == 64 && Sys.ARCH in (:x86_64, :aarch64) || return false
    try
        compute_syscall_number("read") >= 0 && compute_syscall_number("write") >= 0
    catch
        false
    end
end

function compute_descriptor_audit()
    Sys.islinux() || throw(ShenScopeError(:sandbox, "Compute descriptor audit requires Linux"))
    entries = readdir("/proc/self/fd")
    count = 0
    jit_descriptors = Int[]
    for entry in entries
        descriptor = tryparse(Int, entry)
        descriptor === nothing && continue
        path = "/proc/self/fd/" * entry
        target = try
            readlink(path)
        catch cause
            # readdir's own descriptor is gone after collecting entries.
            !ispath(path) && !islink(path) && continue
            rethrow(cause)
        end
        safe = startswith(target, "pipe:[") || target in (
            "anon_inode:[eventpoll]", "anon_inode:[eventfd]", "anon_inode:[timerfd]",
            "anon_inode:[signalfd]")
        if target == "/dev/null"
            metadata = stat(Base.RawFD(descriptor))
            safe = metadata.mode & 0o170000 == 0o020000 && metadata.rdev == 0x103
        elseif target == "/memfd:julia-codegen (deleted)"
            # Anonymous LLVM code storage has no host filesystem pathname.
            push!(jit_descriptors, descriptor)
            safe = true
        end
        safe || throw(ShenScopeError(:sandbox, "Compute process inherited a non-IPC descriptor"))
        descriptor <= 2 && !startswith(target, "pipe:[") &&
            throw(ShenScopeError(:sandbox, "Compute standard streams must be pipes"))
        count += 1
    end
    count >= 3 || throw(ShenScopeError(:sandbox, "Compute standard streams are incomplete"))
    (count=count, jit_descriptors=jit_descriptors)
end

function compute_mapping_audit()
    for line in eachline("/proc/self/maps")
        fields = split(line;limit=6)
        length(fields) >= 5 || throw(ShenScopeError(:sandbox,"Compute memory map inventory is malformed"))
        permissions = fields[2]
        length(permissions) == 4 || throw(ShenScopeError(:sandbox,"Compute memory map permissions are malformed"))
        # Closing a descriptor does not retire an already established mapping.
        # A shared writable host-file mapping would bypass write/open filtering.
        if permissions[2] == 'w' && permissions[4] == 's' && length(fields) == 6
            path = fields[6]
            startswith(path,"/memfd:julia-codegen ") || startswith(path,"/dev/zero (deleted)") ||
                startswith(path,"[anon") || throw(ShenScopeError(:sandbox,"Compute process retains a shared writable host mapping"))
        end
    end
    nothing
end

function compute_install_seccomp()
    compute_seccomp_available() || throw(ShenScopeError(:sandbox, "Verified compute sandbox is unavailable"))
    get(ENV, "SHENSCOPE_ISOLATED_CHILD", "") == "1" ||
        throw(ShenScopeError(:sandbox, "Compute filter can only be installed in its child process"))
    descriptors = compute_descriptor_audit()
    compute_mapping_audit()
    filter = ccall((:seccomp_init, COMPUTE_SECCOMP_LIBRARY), Ptr{Cvoid}, (UInt32,), COMPUTE_SCMP_DENY)
    filter == C_NULL && throw(ShenScopeError(:sandbox, "Unable to initialize compute filter"))
    try
        # Synchronize every pre-existing Julia/GC/I/O thread. Failure prevents
        # evaluation; filtering only the calling thread is insufficient.
        ccall((:seccomp_attr_set, COMPUTE_SECCOMP_LIBRARY), Cint,
            (Ptr{Cvoid}, Cuint, Cuint), filter, 4, 1) == 0 ||
            throw(ShenScopeError(:sandbox, "Compute thread synchronization is unavailable"))
        allowed = String[]
        for name in ("brk", "munmap", "mprotect", "mremap", "madvise",
                "futex", "futex_waitv", "sched_yield", "sched_getaffinity",
                "clock_gettime", "clock_getres", "gettimeofday", "time",
                "nanosleep", "clock_nanosleep", "getpid", "getppid", "gettid",
                "getuid", "geteuid", "getgid", "getegid", "getrandom",
                "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "sigaltstack",
                "rseq", "membarrier", "set_robust_list", "set_tid_address",
                "restart_syscall", "exit", "exit_group", "close", "fstat", "read", "readv", "write", "writev",
                "poll", "ppoll", "select", "pselect6", "epoll_wait", "epoll_pwait",
                "epoll_pwait2", "epoll_ctl", "epoll_create1", "eventfd2", "getrusage", "uname")
            compute_allow_syscall(filter, name) && push!(allowed, name)
        end
        # No filesystem descriptor can be opened, created, received or duplicated.
        # The closed descriptor inventory contains only IPC, /dev/null and
        # LLVM's anonymous code storage. libuv needs its internal wakeup pipes.
        for command in (1, 3, 1032)
            compute_allow_syscall(filter, "fcntl", [compute_arg_equal(1, command)])
        end
        compute_allow_syscall(filter, "mmap", [compute_arg_mask(3, 0x20, 0x20)]; required=true)
        for descriptor in descriptors.jit_descriptors
            compute_allow_syscall(filter, "mmap", [compute_arg_equal(4, descriptor)])
            compute_allow_syscall(filter, "ftruncate", [compute_arg_equal(0, descriptor),
                ComputeSyscallComparison(UInt32(1), UInt32(3), UInt64(128 * 1024^2), UInt64(0))])
        end
        compute_allow_syscall(filter, "tgkill", [compute_arg_equal(0, getpid())])
        compute_allow_syscall(filter, "prlimit64", [compute_arg_equal(0, 0), compute_arg_equal(2, 0)])
        ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 38, 1, 0, 0, 0) == 0 ||
            throw(ShenScopeError(:sandbox, "Compute no-new-privileges enforcement failed"))
        ccall((:seccomp_load, COMPUTE_SECCOMP_LIBRARY), Cint, (Ptr{Cvoid},), filter) == 0 ||
            throw(ShenScopeError(:sandbox, "Compute system-call enforcement failed"))
        Dict("backend" => "linux-seccomp-compute-v1", "enforced" => true,
            "thread_synchronized" => true, "no_new_privileges" => true,
            "filesystem_open" => false, "filesystem_write" => false,
            "network" => false, "child_processes" => false,
            "descriptor_count" => descriptors.count, "jit_memfd_count" => length(descriptors.jit_descriptors),
            "default_action" => "EACCES",
            "unconditional_calls" => allowed)
    finally
        ccall((:seccomp_release, COMPUTE_SECCOMP_LIBRARY), Cvoid, (Ptr{Cvoid},), filter)
    end
end
