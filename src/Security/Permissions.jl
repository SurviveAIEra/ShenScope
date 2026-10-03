@enum PermissionDecision Allow Ask Deny

struct PermissionRequest
    id::String
    category::Symbol
    tool::String
    target::String
    reason::String
end

mutable struct PermissionPolicy
    rules::Dict{Symbol,PermissionDecision}
    grants::Set{Tuple{Symbol,String}}
    mutex::ReentrantLock
end
function PermissionPolicy(; rules=Dict(:read=>Allow, :edit=>Ask, :process=>Ask,
        :network=>Ask, :mcp=>Ask, :dynamic=>Ask, :persistence=>Ask))
    PermissionPolicy(Dict{Symbol,PermissionDecision}(rules),Set{Tuple{Symbol,String}}(),ReentrantLock())
end
function permission_decision(policy::PermissionPolicy, request::PermissionRequest)
    lock(policy.mutex) do
        decision = get(policy.rules, request.category, Deny)
        decision == Deny && return Deny
        (request.category,request.target) in policy.grants && return Allow
        return decision
    end
end

function workspace_path(root::String, path::AbstractString; must_exist=false)
    isdir(root) || throw(ShenScopeError(:path,"Workspace does not exist"))
    realroot = realpath(root)
    target = normpath(isabspath(path) ? path : joinpath(realroot,path))
    ancestor = target
    suffix = String[]
    while !ispath(ancestor) && !islink(ancestor)
        pushfirst!(suffix,basename(ancestor))
        parent = dirname(ancestor)
        parent == ancestor && throw(ShenScopeError(:path,"Cannot resolve path"))
        ancestor = parent
    end
    resolved = joinpath(realpath(ancestor), suffix...)
    relative = relpath(resolved,realroot)
    parts = splitpath(relative)
    (isabspath(relative) || (!isempty(parts) && first(parts)=="..")) &&
        throw(ShenScopeError(:permission,"Path escapes workspace"))
    any(p -> p in (".git", ".env", ".aws", ".ssh"),parts) &&
        throw(ShenScopeError(:permission,"Protected path"))
    startswith(basename(resolved),".env.") && throw(ShenScopeError(:permission,"Protected secret file"))
    must_exist && !isfile(resolved) && throw(ShenScopeError(:path,"File does not exist"))
    return resolved
end
