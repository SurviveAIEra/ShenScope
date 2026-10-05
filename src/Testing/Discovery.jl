const PROJECT_TEST_PRUNED_DIRECTORIES=Set([".git",".aws",".ssh",".env","node_modules",".venv","venv","__pycache__","target","build","dist","vendor",".cache",".idea"])

mutable struct ProjectTestScan
    files::Int
    directories::Int
    entries::Int
    marker_bytes::Int
    skipped_symlinks::Int
    pruned_directories::Int
    limits_hit::Set{String}
    invalid_markers::Vector{Dict{String,Any}}
    markers::Vector{ProjectTestMarker}
    candidates::Vector{ProjectTestCandidate}
    visited::Set{String}
end
ProjectTestScan()=ProjectTestScan(0,0,0,0,0,0,Set(),Dict{String,Any}[],ProjectTestMarker[],ProjectTestCandidate[],Set())

function project_test_scan_marker!(scan::ProjectTestScan,ctx::RuntimeContext,path::String,limits::ProjectTestDiscoveryLimits)
    remaining=limits.total_marker_bytes-scan.marker_bytes
    remaining>0 || (push!(scan.limits_hit,"total_marker_bytes");return)
    maximum=min(limits.marker_bytes,remaining)
    text=try
        read_scoped_text(ctx,ctx.root,path,maximum;tool="testing",reason="Discover declared project test commands",
            size_error=:testing_marker_size,encoding_error=:testing_marker_encoding)
    catch cause
        if cause isa ShenScopeError && cause.code in (:testing_marker_size,:testing_marker_encoding)
            length(scan.invalid_markers)<128 && push!(scan.invalid_markers,Dict("path"=>relpath(path,ctx.root),"code"=>String(cause.code)))
            cause.code==:testing_marker_size && push!(scan.limits_hit,maximum==remaining ? "total_marker_bytes" : "marker_bytes")
            return
        end
        rethrow()
    end
    scan.marker_bytes+=ncodeunits(text)
    marker=ProjectTestMarker(relpath(path,ctx.root),digest(text),ncodeunits(text))
    push!(scan.markers,marker)
    candidates=try
        occursin('\0',text) && throw(ShenScopeError(:testing,"Project marker contains NUL"))
        project_test_marker_candidates(marker,text)
    catch cause
        cause isa ShenScopeError && cause.code==:testing || rethrow()
        length(scan.invalid_markers)<128 && push!(scan.invalid_markers,Dict("path"=>marker.path,"code"=>"testing"))
        return
    end
    for candidate in candidates
        length(scan.candidates)<limits.candidates || (push!(scan.limits_hit,"candidates");break)
        any(prior->prior.id==candidate.id,scan.candidates) || push!(scan.candidates,candidate)
    end
end

function project_test_scan_directory!(scan::ProjectTestScan,ctx::RuntimeContext,path::String,depth::Int,limits::ProjectTestDiscoveryLimits)
    path in scan.visited && return
    scan.directories<limits.directories || (push!(scan.limits_hit,"directories");return)
    project_test_checkpoint(ctx;read_target=path)
    authorize!(ctx,:read,"testing",path;reason="Discover test entry points in the selected workspace directory")
    project_test_workspace_directory(ctx,path)==path || throw(ShenScopeError(:conflict,"Discovery directory changed"))
    push!(scan.visited,path);scan.directories+=1
    # readdir materializes one directory listing. The traversal and retained
    # entries are bounded; this is not a streaming filesystem memory guarantee.
    entries=readdir(path)
    for name in entries
        scan.entries<limits.directory_entries || (push!(scan.limits_hit,"directory_entries");break)
        scan.entries+=1;project_test_checkpoint(ctx;read_target=path)
        child=joinpath(path,name)
        if islink(child)
            scan.skipped_symlinks+=1;continue
        elseif isdir(child)
            if name in PROJECT_TEST_PRUNED_DIRECTORIES || child==ctx.state_dir
                scan.pruned_directories+=1;continue
            end
            if depth>=limits.depth
                push!(scan.limits_hit,"depth");continue
            end
            project_test_scan_directory!(scan,ctx,child,depth+1,limits)
        elseif isfile(child)
            scan.files<limits.files || (push!(scan.limits_hit,"files");break)
            scan.files+=1
            project_test_is_marker(name) && project_test_scan_marker!(scan,ctx,child,limits)
        end
    end
    project_test_checkpoint(ctx;read_target=path)
    project_test_workspace_directory(ctx,path)==path || throw(ShenScopeError(:conflict,"Discovery directory changed before publication"))
    nothing
end

function discover_project_tests!(manager::ProjectTestManager,ctx::RuntimeContext;
        scopes=["."],limits=ProjectTestDiscoveryLimits())
    scopes isa AbstractVector && 1<=length(scopes)<=16 || throw(ShenScopeError(:testing,"Choose one to sixteen discovery directories"))
    limits isa ProjectTestDiscoveryLimits || throw(ShenScopeError(:testing,"Invalid discovery limits"))
    paths=unique([project_test_workspace_directory(ctx,value) for value in scopes])
    any(path->path==ctx.state_dir,paths) && throw(ShenScopeError(:permission,"Session state is not a project test discovery scope"))
    scan=ProjectTestScan()
    for path in paths
        project_test_scan_directory!(scan,ctx,path,0,limits)
    end
    for marker in scan.markers;project_test_checkpoint(ctx;read_target=joinpath(ctx.root,marker.path));end
    coverage=Dict{String,Any}("files_examined"=>scan.files,"directories_examined"=>scan.directories,
        "entries_examined"=>scan.entries,"marker_bytes"=>scan.marker_bytes,"skipped_symlinks"=>scan.skipped_symlinks,
        "pruned_directories"=>scan.pruned_directories,"limits_hit"=>sort!(collect(scan.limits_hit)),
        "invalid_markers"=>scan.invalid_markers,"complete_project_inventory"=>false,
        "status"=>isempty(scan.limits_hit) && isempty(scan.invalid_markers) ? "bounded_scan_complete" : "partial")
    provisional=ProjectTestCatalog("",ctx.session_id,digest(ctx.root),utcstamp(),relpath.(paths,Ref(ctx.root)),
        scan.candidates,scan.markers,coverage,limits)
    id=digest(bounded_canonical_json(project_test_catalog_body(provisional);maximum=2*1024^2,max_nodes=100_000))
    catalog=ProjectTestCatalog(id,provisional.owner,provisional.root_sha256,provisional.created_at,provisional.scopes,
        provisional.candidates,provisional.markers,provisional.coverage,provisional.limits)
    lock(manager.mutex) do
        if length(manager.catalogs)>=manager.max_catalogs
            oldest=first(sort!(collect(values(manager.catalogs));by=value->value[2].created_at))[2].id
            delete!(manager.catalogs,oldest)
        end
        manager.catalogs[id]=(operation_scope(ctx),catalog)
    end
    project_test_catalog_view(catalog)
end
