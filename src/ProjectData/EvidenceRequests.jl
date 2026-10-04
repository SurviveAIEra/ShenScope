function evidence_limits(arguments::AbstractDict)
    symbols=project_query_integer(arguments,"max_symbols",20000,1,20000)
    relations=project_query_integer(arguments,"max_relations",100000,1,100000)
    depth=project_query_integer(arguments,"max_depth",8,0,32)
    confidence=get(arguments,"minimum_confidence",0.0)
    confidence isa Real && !(confidence isa Bool) && isfinite(confidence) && 0<=confidence<=1 ||
        throw(ShenScopeError(:arguments,"Invalid evidence confidence threshold"))
    bridges=get(arguments,"include_bridges",true)
    bridges isa Bool || throw(ShenScopeError(:arguments,"Evidence bridge option must be boolean"))
    EvidenceLimits(8,symbols,relations,PROJECT_EVIDENCE_MAX_BYTES,depth,Float64(confidence),bridges)
end

function evidence_backend_names(arguments::AbstractDict)
    names=get(arguments,"backends",nothing)
    names isa AbstractVector && 2<=length(names)<=8 &&
        all(name->name isa AbstractString && occursin(r"^[a-z][a-z0-9_]{0,63}$",name),names) ||
        throw(ShenScopeError(:arguments,"Select between two and eight indexed evidence backends"))
    length(unique(names))==length(names) || throw(ShenScopeError(:arguments,"Evidence backends must be distinct"))
    sort!(String.(names))
end

function evidence_paths(arguments::AbstractDict,ctx::RuntimeContext;key="paths")
    raw=get(arguments,key,String[])
    raw isa AbstractVector && length(raw)<=512 && all(path->path isa AbstractString && ncodeunits(path)<=4096,raw) ||
        throw(ShenScopeError(:arguments,"Invalid evidence path selection"))
    sort!(unique([replace(relpath(workspace_path(ctx.root,path),ctx.root),'\\'=>'/') for path in raw]))
end

function evidence_expected_revisions(arguments::AbstractDict,names::Vector{String})
    raw=get(arguments,"source_revisions",Dict{String,Any}())
    raw isa AbstractDict && length(raw)<=8 && all(key->key in names,keys(raw)) ||
        throw(ShenScopeError(:arguments,"Invalid evidence revision vector"))
    result=Dict{String,Int}()
    for (key,value) in raw
        value isa Integer && !(value isa Bool) && 0<=value<=typemax(Int) ||
            throw(ShenScopeError(:arguments,"Evidence source revisions must be nonnegative integers"))
        result[String(key)]=Int(value)
    end
    result
end

function evidence_checkpoint(ctx::RuntimeContext)
    project_query_tick(ctx)
    request=PermissionRequest("project-evidence",:read,"project.evidence",ctx.root,"Read combined indexed evidence")
    permission_decision(ctx.permissions,request)!=Deny ||
        throw(ShenScopeError(:permission,"Combined project evidence reads were revoked"))
end

function evidence_charge_bytes(bytes::Int,value,limits::EvidenceLimits)
    bytes+=ncodeunits(canonical(value))
    bytes<=limits.bytes || throw(ShenScopeError(:capacity,"Combined project evidence exceeds memory capacity; select fewer paths"))
    bytes
end
