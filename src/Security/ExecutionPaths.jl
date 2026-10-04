function execution_contains(root::String,path::String)
    parts=splitpath(relpath(path,root))
    !isabspath(relpath(path,root)) && (isempty(parts) || first(parts)!="..")
end

function execution_mount(source::String,destination::String,writable::Bool)
    ispath(source) || throw(ShenScopeError(:sandbox,"Execution mount source is missing"))
    actual=realpath(source);info=stat(actual)
    (isdir(actual) || isfile(actual)) || throw(ShenScopeError(:sandbox,"Execution mount must be a file or directory"))
    ExecutionMount(actual,destination,writable,isdir(actual) ? :directory : :file,
        (UInt64(info.device),UInt64(info.inode)))
end

function execution_worker_path()
    realpath(joinpath(@__DIR__,"ExecutionWorker.jl"))
end

function execution_julia_path()
    realpath(joinpath(Sys.BINDIR,Base.julia_exename()))
end

function execution_bwrap_path()
    Sys.islinux() || throw(ShenScopeError(:sandbox,"Bubblewrap requires Linux"))
    for candidate in ("/usr/bin/bwrap","/bin/bwrap")
        isfile(candidate) || continue
        actual=realpath(candidate);info=stat(actual)
        (info.uid==0 || ccall(:access,Cint,(Cstring,Cint),actual,2)!=0) && (info.mode & 0o022)==0 ||
            throw(ShenScopeError(:sandbox,"Bubblewrap executable is not a protected system dependency"))
        return actual
    end
    throw(ShenScopeError(:sandbox,"A protected system bubblewrap executable is unavailable"))
end

function execution_protected_masks(ctx::RuntimeContext;scan_limit=EXECUTION_MAX_SCAN_ENTRIES)
    scan_limit isa Integer && !(scan_limit isa Bool) && 1<=scan_limit<=EXECUTION_MAX_SCAN_ENTRIES ||
        throw(ShenScopeError(:arguments,"Invalid execution workspace scan limit"))
    masks=ExecutionMask[];pending=String[ctx.root];visited=0
    while !isempty(pending)
        directory=pop!(pending)
        for name in readdir(directory)
            visited+=1
            visited<=scan_limit || throw(ShenScopeError(:capacity,"Execution protected-path scan is incomplete"))
            visited%128==0 && (check_cancelled(ctx.cancellation);lock(ctx.budget.mutex) do;check_budget(ctx.budget);end;yield())
            path=joinpath(directory,name)
            protected=name in (".git",".env",".aws",".ssh") || startswith(name,".env.")
            if protected
                islink(path) && throw(ShenScopeError(:sandbox,"A protected execution path is a symbolic link"))
                kind=name==".git" ? :read_only : isdir(path) ? :directory : :file
                push!(masks,ExecutionMask(path,kind))
                length(masks)<=EXECUTION_MAX_MASKS || throw(ShenScopeError(:capacity,"Too many protected execution paths"))
            elseif isdir(path) && !islink(path)
                if normpath(path)!=normpath(ctx.state_dir)
                    push!(pending,path)
                end
            end
        end
    end
    if execution_contains(ctx.root,ctx.state_dir)
        ctx.state_dir!=ctx.root || throw(ShenScopeError(:sandbox,"Execution workspace cannot equal private Core state"))
        islink(ctx.state_dir) && throw(ShenScopeError(:sandbox,"Private Core state path is a symbolic link"))
        push!(masks,ExecutionMask(ctx.state_dir,isfile(ctx.state_dir) ? :file : :directory))
    end
    length(masks)<=EXECUTION_MAX_MASKS || throw(ShenScopeError(:capacity,"Too many protected execution paths"))
    Tuple(sort!(unique(masks);by=mask->mask.path))
end

function execution_runtime_mounts(policy::ExecutionPolicy,ctx::RuntimeContext)
    mounts=ExecutionMount[]
    julia_root=dirname(Sys.BINDIR)
    roots=unique(vcat(collect(policy.runtime_roots),[julia_root]))
    for source in roots
        ispath(source) || continue
        actual=realpath(source)
        (execution_contains(actual,ctx.root) || execution_contains(ctx.root,actual) ||
            execution_contains(actual,abspath(ctx.state_dir))) &&
            throw(ShenScopeError(:sandbox,"Runtime mounts overlap workspace or private state"))
        push!(mounts,execution_mount(source,source,false))
    end
    system_paths=String["/etc/ld.so.cache","/etc/ssl/certs"]
    policy.network==:open && append!(system_paths,["/etc/resolv.conf","/etc/hosts","/etc/nsswitch.conf"])
    for path in system_paths
        ispath(path) && push!(mounts,execution_mount(path,path,false))
    end
    push!(mounts,execution_mount(execution_worker_path(),"/shenscope-exec.jl",false))
    sort!(mounts;by=mount->(length(splitpath(mount.destination)),mount.destination))
end

function execution_validate_mounts(plan::ExecutionPlan,ctx::RuntimeContext)
    realpath(ctx.root)==plan.workspace && realpath(plan.cwd)==plan.cwd ||
        throw(ShenScopeError(:conflict,"Execution workspace/directory changed after preparation"))
    for mount in plan.mounts
        check_cancelled(ctx.cancellation)
        ispath(mount.source) && realpath(mount.source)==mount.source ||
            throw(ShenScopeError(:conflict,"Execution mount changed after preparation"))
        info=stat(mount.source)
        (UInt64(info.device),UInt64(info.inode))==mount.identity ||
            throw(ShenScopeError(:conflict,"Execution mount identity changed after preparation"))
    end
    for mask in plan.masks
        islink(mask.path) && throw(ShenScopeError(:conflict,"Execution protected path became a symbolic link"))
    end
    nothing
end
