struct ReadTool <: AbstractTool end
struct SearchTool <: AbstractTool end
struct EditTool <: AbstractTool end
struct WriteTool <: AbstractTool end
struct PatchTool <: AbstractTool end

tool_name(::ReadTool)="read"
tool_name(::SearchTool)="search"
tool_name(::EditTool)="edit"
tool_name(::WriteTool)="write"
tool_name(::PatchTool)="patch"
execution_mode(::ReadTool)=:parallel
execution_mode(::SearchTool)=:parallel
tool_description(::ReadTool)="Read workspace text with source lines and SHA-256 for conflict-safe editing."
tool_description(::SearchTool)="Search workspace text literally, bounded by result count."
tool_description(::EditTool)="Replace one exact text occurrence, requiring the SHA-256 from read."
tool_description(::WriteTool)="Create a new text file. Existing files cannot be overwritten."
tool_description(::PatchTool)="Validate all hash-protected replacements before applying a multi-file patch."

tool_schema(::ReadTool)=object_schema(Dict("path"=>string_schema(;max=4096),
    "start_line"=>integer_schema(1),"end_line"=>integer_schema(1));required=["path"])
tool_schema(::SearchTool)=object_schema(Dict("query"=>string_schema(;max=4096),
    "path"=>string_schema(;max=4096),"limit"=>integer_schema(1,1000));required=["query"])
tool_schema(::EditTool)=object_schema(Dict("path"=>string_schema(;max=4096),"old"=>string_schema(),
    "new"=>string_schema(),"expected_sha256"=>string_schema(;max=64)))
tool_schema(::WriteTool)=object_schema(Dict("path"=>string_schema(;max=4096),"content"=>string_schema()))
tool_schema(::PatchTool)=object_schema(Dict("edits"=>Dict("type"=>"array","minItems"=>1,"maxItems"=>100,
    "items"=>tool_schema(EditTool()))))

function read_workspace_text(ctx::RuntimeContext,path::AbstractString;max_bytes=4*1024*1024)
    p=workspace_path(ctx.root,path;must_exist=true)
    filesize(p)<=max_bytes || throw(ShenScopeError(:output,"File exceeds readable size limit"))
    text=read(p,String)
    isvalid(text) && !occursin('\0',text) || throw(ShenScopeError(:input,"File is not UTF-8 text"))
    return p,text
end

function execute(::ReadTool,args::AbstractDict,ctx::RuntimeContext)
    p=workspace_path(ctx.root,args["path"];must_exist=true)
    authorize!(ctx,:read,"read",p)
    _,text=read_workspace_text(ctx,args["path"])
    lines=split(text,'\n');start=get(args,"start_line",1);finish=get(args,"end_line",min(length(lines),start+399))
    start<=finish || throw(ShenScopeError(:arguments,"Invalid line range"))
    start<=length(lines) || throw(ShenScopeError(:arguments,"Start line exceeds file"))
    finish=min(finish,length(lines))
    numbered=join((string(i) * ": " * lines[i] for i in start:finish),"\n")
    return Dict("path"=>relpath(p,ctx.root),"sha256"=>digest(text),"total_lines"=>length(lines),
        "start_line"=>start,"end_line"=>finish,"text"=>cliptext(numbered,64*1024))
end

const SKIP_DIRS=Set([".git",".local",".ssh",".aws","node_modules","__pycache__","dist","build","target",".venv"])
function workspace_files(root::String)
    result=String[]
    for (dir,dirs,files) in walkdir(root;follow_symlinks=false)
        filter!(d->!(d in SKIP_DIRS) && !islink(joinpath(dir,d)),dirs)
        for file in files
            p=joinpath(dir,file)
            islink(p) && continue
            (file==".env" || startswith(file,".env.")) && continue
            push!(result,p)
        end
    end
    return sort!(result)
end

function execute(::SearchTool,args::AbstractDict,ctx::RuntimeContext)
    query=args["query"]
    isempty(query) && throw(ShenScopeError(:arguments,"Search query is empty"))
    path=workspace_path(ctx.root,get(args,"path","."))
    authorize!(ctx,:read,"search",path)
    paths=isdir(path) ? workspace_files(path) : [path]
    limit=get(args,"limit",100);matches=Dict{String,Any}[];scanned=0
    for p in paths
        check_cancelled(ctx.cancellation)
        filesize(p)>4*1024*1024 && continue
        _,text=read_workspace_text(ctx,p)
        scanned+=1
        for (i,line) in enumerate(split(text,'\n'))
            occursin(query,line) || continue
            push!(matches,Dict("path"=>relpath(p,ctx.root),"line"=>i,"text"=>cliptext(line,2048)))
            length(matches)>=limit && return Dict("matches"=>matches,"limited"=>true,"scanned"=>scanned)
        end
    end
    return Dict("matches"=>matches,"limited"=>false,"scanned"=>scanned)
end

function prepare_edit(args::AbstractDict,ctx::RuntimeContext)
    p,text=read_workspace_text(ctx,args["path"])
    digest(text)==args["expected_sha256"] || throw(ShenScopeError(:conflict,"File changed since observation"))
    old=args["old"];new=args["new"]
    isempty(old) && throw(ShenScopeError(:arguments,"Empty match is not allowed"))
    length(findall(old,text))==1 || throw(ShenScopeError(:conflict,"Replacement must match exactly once"))
    return p,text,replace(text,old=>new;count=1)
end

function execute(::EditTool,args::AbstractDict,ctx::RuntimeContext)
    p=workspace_path(ctx.root,args["path"];must_exist=true)
    authorize!(ctx,:edit,"edit",p)
    return store_lock(joinpath(ctx.state_dir,"file-locks",digest(p))) do
        target,before,after=prepare_edit(args,ctx)
        atomic_write(target,after;mode=filemode(target)&0o777)
        emit!(ctx,:file_changed,Dict("path"=>relpath(target,ctx.root),"before_sha256"=>digest(before),"after_sha256"=>digest(after)))
        return Dict("path"=>relpath(target,ctx.root),"sha256"=>digest(after),"changed"=>before!=after)
    end
end

function execute(::WriteTool,args::AbstractDict,ctx::RuntimeContext)
    p=workspace_path(ctx.root,args["path"])
    authorize!(ctx,:edit,"write",p)
    return store_lock(joinpath(ctx.state_dir,"file-locks",digest(p))) do
        ispath(p) && throw(ShenScopeError(:conflict,"File already exists"))
        atomic_write(p,args["content"];mode=0o644)
        emit!(ctx,:file_changed,Dict("path"=>relpath(p,ctx.root),"after_sha256"=>digest(args["content"])))
        return Dict("path"=>relpath(p,ctx.root),"sha256"=>digest(args["content"]))
    end
end

function execute(::PatchTool,args::AbstractDict,ctx::RuntimeContext)
    authorize!(ctx,:edit,"patch",ctx.root;reason="Apply hash-protected multi-file patch")
    # Validation-before-write prevents malformed later edits from leaving an
    # earlier partial patch. Rollback handles ordinary I/O errors, not power loss.
    plan=[prepare_edit(a,ctx) for a in args["edits"]]
    length(unique(p[1] for p in plan))==length(plan) || throw(ShenScopeError(:arguments,"Duplicate patch path"))
    applied=Tuple{String,String,UInt}[]
    try
        for (p,before,after) in plan
            check_cancelled(ctx.cancellation)
            digest(read(p,String))==digest(before) || throw(ShenScopeError(:conflict,"Patch file changed during validation"))
            mode=filemode(p)&0o777
            atomic_write(p,after;mode)
            push!(applied,(p,before,mode))
        end
    catch
        for (p,before,mode) in reverse(applied);atomic_write(p,before;mode);end
        rethrow()
    end
    result=[Dict("path"=>relpath(p,ctx.root),"sha256"=>digest(after)) for (p,_,after) in plan]
    emit!(ctx,:patch_applied,result)
    return result
end
