function runtime_source_paths(root::String,ctx::RuntimeContext)
    root==realpath(root) && !islink(root) || throw(ShenScopeError(:runtime_image,"Runtime source root must be a real directory"))
    paths=String["Project.toml","Manifest.toml"]
    isfile(joinpath(root,"LocalPreferences.toml")) && push!(paths,"LocalPreferences.toml")
    entries=0
    for directory in ("src","ext")
        base=joinpath(root,directory)
        islink(base) && throw(ShenScopeError(:runtime_image,"Runtime source directory symlinks are unsupported"))
        isdir(base) || continue
        for (folder,dirs,files) in walkdir(base;follow_symlinks=false)
            runtime_artifact_checkpoint(ctx;target=root)
            entries+=length(dirs)+length(files)
            entries<=4*RUNTIME_SOURCE_MAX_FILES || throw(ShenScopeError(:capacity,"Runtime source directory scan exceeds capacity"))
            for name in dirs
                islink(joinpath(folder,name)) && throw(ShenScopeError(:runtime_image,"Runtime source symlink directories are unsupported"))
            end
            for name in files
                endswith(name,".jl") || continue
                path=joinpath(folder,name)
                islink(path) && throw(ShenScopeError(:runtime_image,"Runtime source file symlinks are unsupported"))
                push!(paths,replace(relpath(path,root),'\\'=>'/'))
                length(paths)<=RUNTIME_SOURCE_MAX_FILES || throw(ShenScopeError(:capacity,"Runtime source file count exceeds capacity"))
            end
        end
    end
    "src/ShenScope.jl" in paths || throw(ShenScopeError(:runtime_image,"Runtime Core entry source is missing"))
    sort!(paths)
end

function runtime_source_snapshot(ctx::RuntimeContext;root=runtime_core_root())
    source_root=realpath(String(root))
    authorize!(ctx,:read,"runtime.source",source_root;reason="Fingerprint Core source, dependency lock and package preferences")
    paths=runtime_source_paths(source_root,ctx)
    files=RuntimeSourceFile[];total=0;project=nothing
    for relative in paths
        runtime_artifact_checkpoint(ctx;tool="runtime.source",target=source_root)
        text=read_scoped_text(ctx,source_root,relative,RUNTIME_SOURCE_MAX_FILE_BYTES;authorized=true,tool="runtime.source")
        total+=ncodeunits(text)
        total<=RUNTIME_SOURCE_MAX_BYTES || throw(ShenScopeError(:capacity,"Runtime source bytes exceed capacity"))
        push!(files,RuntimeSourceFile(relative,ncodeunits(text),digest(text)))
        relative=="Project.toml" && (project=try TOML.parse(text) catch;throw(ShenScopeError(:runtime_image,"Invalid Core project metadata"));end)
    end
    paths==runtime_source_paths(source_root,ctx) || throw(ShenScopeError(:conflict,"Runtime source membership changed during capture"))
    get(project,"name",nothing)=="ShenScope" || throw(ShenScopeError(:runtime_image,"Source package is not ShenScope"))
    uuid=try UUID(project["uuid"]) catch;throw(ShenScopeError(:runtime_image,"Invalid Core package UUID"));end
    uuid==Base.PkgId(@__MODULE__).uuid || throw(ShenScopeError(:runtime_image,"Core source UUID does not match this package"))
    version=try VersionNumber(project["version"]) catch;throw(ShenScopeError(:runtime_image,"Invalid Core package version"));end
    identity=Dict("name"=>"ShenScope","uuid"=>string(uuid),"version"=>string(version),"files"=>runtime_source_file_view.(files))
    RuntimeSourceSnapshot(source_root,"ShenScope",uuid,version,files,digest(canonical(identity)))
end

function runtime_source_from_view(value::AbstractDict;root="")
    Set(keys(value))==Set(["name","uuid","version","files","fingerprint"]) ||
        throw(ShenScopeError(:runtime_image,"Unknown or missing runtime source receipt fields"))
    value["name"]=="ShenScope" || throw(ShenScopeError(:runtime_image,"Receipt does not describe ShenScope"))
    rows=value["files"]
    rows isa AbstractVector && 3<=length(rows)<=RUNTIME_SOURCE_MAX_FILES || throw(ShenScopeError(:runtime_image,"Invalid runtime source receipt count"))
    files=RuntimeSourceFile[]
    for row in rows
        row isa AbstractDict && Set(keys(row))==Set(["path","bytes","sha256"]) ||
            throw(ShenScopeError(:runtime_image,"Invalid runtime source receipt row"))
        row["path"] isa String && row["bytes"] isa Integer && row["sha256"] isa String ||
            throw(ShenScopeError(:runtime_image,"Invalid runtime source receipt row types"))
        push!(files,RuntimeSourceFile(row["path"],row["bytes"],row["sha256"]))
    end
    names=getfield.(files,:path)
    issorted(names) && length(unique(names))==length(names) &&
        all(path->path in names,("Project.toml","Manifest.toml","src/ShenScope.jl")) ||
        throw(ShenScopeError(:runtime_image,"Runtime source receipt paths must be sorted, unique and complete"))
    sum(file.bytes for file in files)<=RUNTIME_SOURCE_MAX_BYTES || throw(ShenScopeError(:capacity,"Runtime source receipt bytes exceed capacity"))
    uuid=try UUID(value["uuid"]) catch;throw(ShenScopeError(:runtime_image,"Invalid source receipt UUID"));end
    version=try VersionNumber(value["version"]) catch;throw(ShenScopeError(:runtime_image,"Invalid source receipt version"));end
    identity=Dict("name"=>value["name"],"uuid"=>string(uuid),"version"=>string(version),"files"=>runtime_source_file_view.(files))
    fingerprint=digest(canonical(identity))
    fingerprint==value["fingerprint"] || throw(ShenScopeError(:runtime_image,"Runtime source receipt fingerprint does not match its inventory"))
    RuntimeSourceSnapshot(String(root),"ShenScope",uuid,version,files,fingerprint)
end
