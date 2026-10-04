function execution_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    yield()
end

function execution_worker_arguments(policy::ExecutionPolicy,nonce::String,sha::String,argv;
        backend="bubblewrap",worker="/shenscope-exec.jl")
    limits=policy.limits
    String[execution_julia_path(),"--startup-file=no","--history-file=no","--compiled-modules=no",
        "--threads=1","--gcthreads=1",worker,nonce,sha,String(policy.network),
        string(limits.cpu_seconds),string(limits.file_bytes),string(limits.open_files),
        string(limits.address_space_bytes),backend,"--",argv...]
end

function execution_bwrap_command(mounts,masks,environment,cwd::String,payload,network::Symbol)
    command=String[execution_bwrap_path(),"--unshare-all","--die-with-parent","--new-session",
        "--cap-drop","ALL","--clearenv","--tmpfs","/"]
    network==:open && append!(command,["--share-net"])
    created=Set{String}(["/"]);bound=String[]
    function directory(path)
        path in created && return
        any(root->execution_contains(root,path),bound) && return
        parent=dirname(path);parent!=path && directory(parent)
        append!(command,["--dir",path]);push!(created,path)
    end
    for mount in mounts
        execution_contains("/tmp",mount.destination) && continue
        directory(dirname(mount.destination))
        append!(command,[mount.writable ? "--bind" : "--ro-bind",mount.source,mount.destination])
        mount.kind==:directory && push!(bound,mount.destination)
    end
    for path in ("/proc","/dev","/tmp");directory(path);end
    append!(command,["--proc","/proc","--dev","/dev","--tmpfs","/tmp"])
    # Workspace mounts below /tmp must follow the private /tmp mount.
    for mount in mounts
        execution_contains("/tmp",mount.destination) || continue
        directory(dirname(mount.destination))
        append!(command,[mount.writable ? "--bind" : "--ro-bind",mount.source,mount.destination])
        mount.kind==:directory && push!(bound,mount.destination)
    end
    append!(command,["--dir","/tmp/shenscope-home","--dir","/tmp/shenscope-cache"])
    for mask in masks
        if mask.kind==:read_only
            append!(command,["--ro-bind",mask.path,mask.path])
        elseif mask.kind==:directory
            append!(command,["--tmpfs",mask.path,"--remount-ro",mask.path])
        else
            append!(command,["--ro-bind","/dev/null",mask.path])
        end
    end
    for (key,value) in environment;append!(command,["--setenv",key,value]);end
    append!(command,["--remount-ro","/","--chdir",cwd,"--",payload...])
    command
end

function execution_plan(sandbox::BubblewrapSandbox,argv::Vector{String},ctx::RuntimeContext;
        cwd=ctx.root,environment=nothing,scan_limit=EXECUTION_MAX_SCAN_ENTRIES)
    Sys.islinux() || throw(ShenScopeError(:sandbox,"Bubblewrap execution requires Linux"))
    policy=sandbox.policy
    path=workspace_path(ctx.root,cwd)
    isdir(path) || throw(ShenScopeError(:path,"Execution directory does not exist"))
    authorize!(ctx,:read,"process.filesystem",ctx.root;reason="Read workspace in restricted command")
    policy.filesystem==:workspace_write && authorize!(ctx,:edit,"process.filesystem",ctx.root;
        reason="Allow command writes within the workspace, excluding protected paths")
    policy.network==:open && authorize!(ctx,:network,"process.network","*";
        reason="Allow command networking without a domain allowlist")
    execution_checkpoint(ctx)
    mounts=execution_runtime_mounts(policy,ctx)
    push!(mounts,execution_mount(ctx.root,ctx.root,policy.filesystem==:workspace_write))
    masks=execution_protected_masks(ctx;scan_limit)
    any(mask->execution_contains(mask.path,path),masks) &&
        throw(ShenScopeError(:permission,"Execution directory is within a protected path"))
    values=execution_environment(policy;overlay=environment)
    identity=Dict("policy"=>execution_policy_view(policy),"workspace"=>ctx.root,"cwd"=>path,
        "mounts"=>[Dict("source"=>m.source,"destination"=>m.destination,"writable"=>m.writable,
            "device"=>m.identity[1],"inode"=>m.identity[2]) for m in mounts],
        "masks"=>[Dict("path"=>m.path,"kind"=>String(m.kind)) for m in masks],
        "environment"=>execution_environment_view(values))
    sha=digest(canonical(identity));nonce=digest(string(uuid4())*string(uuid4()))
    payload=execution_worker_arguments(policy,nonce,sha,argv)
    command=execution_bwrap_command(mounts,masks,values,path,payload,policy.network)
    ExecutionPlan(:bubblewrap,ctx.root,path,Tuple(argv),Tuple(mounts),masks,values,policy,sha,nonce,Tuple(command))
end

function execution_request_view(plan::ExecutionPlan)
    Dict("backend"=>String(plan.backend),"policy_sha256"=>plan.policy_sha256,
        "filesystem"=>String(plan.policy.filesystem),"network"=>String(plan.policy.network),
        "workspace"=>plan.workspace,"cwd"=>plan.cwd,"argv"=>collect(plan.argv),
        "read_only_runtime_paths"=>unique([mount.source for mount in plan.mounts if
            mount.destination!=plan.workspace && mount.source!=execution_worker_path()]),
        "environment"=>execution_environment_view(plan.environment),
        "limits"=>execution_policy_view(plan.policy)["limits"],"protected_paths"=>length(plan.masks))
end

function execution_recheck_permissions(plan::ExecutionPlan,ctx::RuntimeContext)
    decisions=Tuple{Symbol,String,String}[(:read,"process.filesystem",plan.workspace)]
    plan.policy.filesystem==:workspace_write && push!(decisions,(:edit,"process.filesystem",plan.workspace))
    plan.policy.network==:open && push!(decisions,(:network,"process.network","*"))
    for (category,tool,target) in decisions
        permission_decision(ctx.permissions,PermissionRequest("execution-recheck",category,tool,target,"Recheck execution policy"))==Deny &&
            throw(ShenScopeError(:permission,"Execution policy permission was revoked"))
    end
    execution_checkpoint(ctx);execution_validate_mounts(plan,ctx)
end
