const ANALYZER_ARCHIVE_FORMAT = 1

struct AnalyzerArchive
    directory::String
    scope::Symbol
    owner::String
    state_dir::String
    pointers::VersionedStore
    max_versions::Int
    max_bytes::Int
end

function analyzer_archive(ctx::RuntimeContext;scope=:project,max_versions=128,max_bytes=64 * 1024^2)
    scope in (:project,:user) || throw(ShenScopeError(:analysis,"Analyzer archive scope must be project or user"))
    max_versions isa Integer && !(max_versions isa Bool) && 1 <= max_versions <= 512 &&
        max_bytes isa Integer && !(max_bytes isa Bool) && 1024 <= max_bytes <= 256 * 1024^2 ||
        throw(ShenScopeError(:arguments,"Invalid analyzer archive capacity"))
    owner = scope == :project ? digest(ctx.root) : "user"
    directory = joinpath(ctx.state_dir,"analyzers",String(scope),owner)
    pointers = VersionedStore(joinpath(directory,"pointers.jsonl");max_entries=64,
        max_log_bytes=8 * 1024^2,history_limit=16)
    AnalyzerArchive(directory,scope,owner,ctx.state_dir,pointers,Int(max_versions),Int(max_bytes))
end

function analyzer_archive_guard(archive::AnalyzerArchive,ctx::RuntimeContext)
    archive.state_dir == ctx.state_dir && (archive.scope == :user || archive.owner == digest(ctx.root)) ||
        throw(ShenScopeError(:permission,"Analyzer archive belongs to another state directory or project"))
    expected = joinpath(ctx.state_dir,"analyzers",String(archive.scope),archive.owner)
    archive.directory == expected && archive.pointers.journal.path == joinpath(expected,"pointers.jsonl") ||
        throw(ShenScopeError(:permission,"Analyzer archive directory differs from its scope"))
    ancestor = archive.directory
    while !ispath(ancestor) && !islink(ancestor)
        parent = dirname(ancestor)
        parent != ancestor || throw(ShenScopeError(:storage,"Analyzer archive has no existing ancestor"))
        ancestor = parent
    end
    isdir(ancestor) && !islink(ancestor) && realpath(ancestor) == ancestor ||
        throw(ShenScopeError(:permission,"Analyzer archive cannot follow directory aliases"))
    Sys.isunix() && UInt64(stat(ancestor).uid) != UInt64(ccall(:geteuid,Cuint,())) &&
        ancestor == archive.directory && throw(ShenScopeError(:permission,"Analyzer archive has another owner"))
    nothing
end

function analyzer_archive_path(archive::AnalyzerArchive,name::AbstractString,version::AbstractString)
    analyzer_name_valid(name) && occursin(r"^[a-f0-9]{64}$",version) ||
        throw(ShenScopeError(:analysis,"Invalid archived analyzer identity"))
    joinpath(archive.directory,String(name),String(version)*".json")
end

function analyzer_archive_target(archive::AnalyzerArchive,action,name,version;expected_pointer=nothing)
    canonical(Dict("action"=>action,"scope"=>String(archive.scope),"owner"=>archive.owner,
        "name"=>name,"version"=>version,"expected_pointer"=>expected_pointer))
end

function analyzer_archive_authorize!(archive::AnalyzerArchive,ctx::RuntimeContext,category::Symbol,action,name,version;
        expected_pointer=nothing)
    analyzer_archive_guard(archive,ctx)
    target = analyzer_archive_target(archive,action,name,version;expected_pointer)
    authorize!(ctx,category,"analysis."*action,target;reason="$(uppercasefirst(action)) scoped analyzer version")
    analyzer_archive_checkpoint(archive,ctx,category,target)
    target
end

function analyzer_archive_checkpoint(archive::AnalyzerArchive,ctx::RuntimeContext,category::Symbol,target::String)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    permission_decision(ctx.permissions,PermissionRequest("analyzer-archive-current",category,
        "analysis.archive",target,"Recheck archive operation")) != Deny ||
        throw(ShenScopeError(:permission,"Analyzer archive permission was revoked"))
    analyzer_archive_guard(archive,ctx)
    nothing
end

function analyzer_archive_file_guard(path::String,directory::String)
    !islink(path) && (!ispath(path) || isfile(path)) || throw(ShenScopeError(:permission,"Analyzer archive file is not a regular file"))
    isdir(dirname(path)) && realpath(dirname(path)) != dirname(path) &&
        throw(ShenScopeError(:permission,"Analyzer archive file directory is aliased"))
    startswith(path,directory*string(Base.Filesystem.path_separator)) || throw(ShenScopeError(:permission,"Analyzer file escapes its archive"))
    if Sys.isunix() && isfile(path)
        UInt64(stat(path).uid) == UInt64(ccall(:geteuid,Cuint,())) || throw(ShenScopeError(:permission,"Analyzer archive file has another owner"))
    end
    nothing
end
