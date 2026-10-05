mutable struct BackendWorker
    argv::Vector{String}
    process::Union{Nothing,Base.Process}
    input::Union{Nothing,Pipe}
    output::Union{Nothing,Pipe}
    error::Union{Nothing,Pipe}
    reader::Union{Nothing,Task}
    diagnostics::OutputBuffer
    mutex::ReentrantLock
    sequence::Int
    pid::Union{Nothing,Int}
    started_argv::Union{Nothing,Vector{String}}
end
BackendWorker(argv::Vector{String})=BackendWorker(argv,nothing,nothing,nothing,nothing,nothing,OutputBuffer(64*1024),ReentrantLock(),0,nothing,nothing)
function worker_kill!(worker::BackendWorker)
    if Sys.islinux() && worker.pid!==nothing
        result=ccall(:kill,Cint,(Cint,Cint),-worker.pid,9)
        result!=0 && worker.process!==nothing && !process_exited(worker.process) && kill(worker.process,Base.SIGKILL)
    elseif worker.process!==nothing && !process_exited(worker.process)
        kill(worker.process,Base.SIGKILL)
    end
end
function worker_close!(worker::BackendWorker;force=false)
    lock(worker.mutex) do
        process=worker.process
        force && worker_kill!(worker)
        worker.input!==nothing && isopen(worker.input) && close(worker.input)
        if process!==nothing && !process_exited(process)
            deadline=time()+5
            while !process_exited(process) && time()<deadline;sleep(0.01);end
            process_exited(process) || worker_kill!(worker)
            wait(process)
        end
        # A helper may exit before children release inherited output pipes.
        worker_kill!(worker)
        for pipe in (worker.input,worker.output,worker.error)
            pipe!==nothing && isopen(pipe) && close(pipe)
        end
        reader=worker.reader
        reader!==nothing && reader!==current_task() && try wait(reader) catch end
        worker.process=nothing;worker.pid=nothing;worker.reader=nothing;worker.started_argv=nothing
        worker.input=nothing;worker.output=nothing;worker.error=nothing
    end
    nothing
end
function worker_validate_command(worker::BackendWorker)
    1<=length(worker.argv)<=128 && all(value->!isempty(value) && ncodeunits(value)<=8192 &&
        !occursin('\0',value),worker.argv) || throw(ShenScopeError(:backend,"Invalid parser command"))
    copy(worker.argv)
end
function worker_executable(argv::Vector{String},root::String)
    name=first(argv)
    candidate=occursin('/',name) || occursin('\\',name) ? normpath(isabspath(name) ? name : joinpath(root,name)) : name
    executable=Sys.which(candidate)
    executable===nothing && throw(ShenScopeError(:backend,"Configured parser executable is unavailable"))
    vcat([String(executable)],argv[2:end])
end
function worker_start!(worker::BackendWorker,ctx::RuntimeContext;reason="Start the configured source parser helper")
    argv=worker_validate_command(worker)
    request=PermissionRequest("backend-current",:process,"project.backend",first(argv),"Start parser")
    permission_decision(ctx.permissions,request)==Deny && throw(ShenScopeError(:permission,"Parser execution is denied"))
    if worker.process!==nothing && !process_exited(worker.process)
        argv==worker.started_argv || throw(ShenScopeError(:backend,"Parser command changed; close the resident helper before restarting"))
        return
    end
    authorize!(ctx,:process,"project.backend",first(argv);reason)
    lock(worker.mutex) do
        argv==worker.argv && permission_decision(ctx.permissions,request)!=Deny ||
            throw(ShenScopeError(:permission,"Parser command or permission changed after approval"))
        check_cancelled(ctx.cancellation)
        lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
        if worker.process!==nothing && !process_exited(worker.process)
            argv==worker.started_argv || throw(ShenScopeError(:backend,"Resident parser command changed"))
            return
        end
        worker_close!(worker)
        input=Pipe();output=Pipe();err=Pipe()
        resolved=worker_executable(argv,ctx.root)
        command=Sys.islinux() ? vcat(worker_executable(["setsid"],ctx.root),resolved) : resolved
        env=Dict(key=>ENV[key] for key in ("PATH","SYSTEMROOT","WINDIR","LD_LIBRARY_PATH","JULIA_DEPOT_PATH") if haskey(ENV,key))
        env["SHENSCOPE_PARSER_CACHE"]=get(ENV,"SHENSCOPE_PARSER_CACHE","/workspace/tool-cache")
        env["PYTHONNOUSERSITE"]="1";env["PYTHONUTF8"]="1";env["OMP_NUM_THREADS"]="2"
        try
            worker.process=run(pipeline(ignorestatus(setenv(Cmd(Cmd(command);dir=ctx.root),env));stdin=input,stdout=output,stderr=err);wait=false)
            worker.pid=getpid(worker.process)
            worker.started_argv=copy(argv)
        catch
            for pipe in (input,output,err);isopen(pipe) && close(pipe);end
            worker.process=nothing;worker.pid=nothing;worker.started_argv=nothing
            throw(ShenScopeError(:backend,"Unable to start the configured parser helper"))
        end
        close(input.out);close(output.in);close(err.in)
        worker.input=input;worker.output=output;worker.error=err
        worker.reader=@async try
            while !eof(err);capture!(worker.diagnostics,readavailable(err));end
        catch
            # stderr is retained diagnostics, never a protocol response.
        finally
            isopen(err) && close(err)
        end
    end
end
function worker_request(worker::BackendWorker,operation::String,params::AbstractDict,ctx::RuntimeContext;
        timeout=120.0,checkpoint=()->nothing)
    isfinite(timeout) && 0<timeout<=3600 || throw(ShenScopeError(:backend,"Invalid parser timeout"))
    lock(worker.mutex) do
        worker.process!==nothing || throw(ShenScopeError(:backend,"Parser helper has not been prepared"))
        worker_validate_command(worker)==worker.started_argv || throw(ShenScopeError(:backend,"Resident parser command changed"))
        request=PermissionRequest("backend-request",:process,"project.backend",first(worker.argv),"Use parser")
        permission_decision(ctx.permissions,request)!=Deny || throw(ShenScopeError(:permission,"Parser execution is now denied"))
        checkpoint()
        worker.sequence+=1;identifier=worker.sequence
        text=canonical(merge(Dict("id"=>identifier,"operation"=>operation),params))*"\n"
        ncodeunits(text)<=32*1024*1024 || throw(ShenScopeError(:backend,"Parser request exceeds limit"))
        task=nothing;writer=nothing
        try
            remaining=lock(ctx.budget.mutex) do
                check_budget(ctx.budget)
                ctx.budget.limits.max_seconds-(time_ns()-ctx.budget.started_ns)/1e9
            end
            deadline=time()+min(timeout,remaining)
            writer=@async begin;write(worker.input,text);flush(worker.input);end
            task=@async bounded_record(worker.output,32*1024*1024)
            while !istaskdone(task) || !istaskdone(writer)
                check_cancelled(ctx.cancellation)
                checkpoint()
                permission_decision(ctx.permissions,request)!=Deny || throw(ShenScopeError(:permission,"Parser execution was denied during extraction"))
                lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
                istaskfailed(writer) && throw(ShenScopeError(:backend,"Parser request pipe failed"))
                time()<deadline || throw(ShenScopeError(:timeout,"Source parser timed out"));sleep(0.01)
            end
            fetch(writer)
            raw=try fetch(task) catch;throw(ShenScopeError(:backend,"Parser response framing failed")) end
            endswith(raw,"\n") || throw(ShenScopeError(:backend,"Parser disconnected during response"))
            result=bounded_json_object(raw;maximum=32*1024*1024,max_depth=32,max_nodes=1_000_000,error_code=:backend)
            check_cancelled(ctx.cancellation)
            checkpoint()
            permission_decision(ctx.permissions,request)!=Deny || throw(ShenScopeError(:permission,"Parser execution was denied before publication"))
            get(result,"id",nothing) isa Integer && !(result["id"] isa Bool) && result["id"]==identifier ||
                throw(ShenScopeError(:backend,"Parser response ID mismatch"))
            if haskey(result,"error")
                fault=result["error"]
                fault isa AbstractDict && !haskey(result,"result") && get(fault,"message",nothing) isa AbstractString ||
                    throw(ShenScopeError(:backend,"Parser error frame is invalid"))
                throw(ShenScopeError(:parse,"Parser rejected source: "*cliptext(fault["message"],2000)))
            end
            haskey(result,"result") || throw(ShenScopeError(:backend,"Parser frame has no result"))
            get(result,"result",nothing)
        catch error
            # A valid rejection frame leaves framing and the prior graph usable.
            # Forcing a DB process to die on a syntax error can corrupt its WAL.
            error isa ShenScopeError && error.code==:parse || worker_close!(worker;force=true)
            for pending in (task,writer)
                pending!==nothing && pending!==current_task() && try wait(pending) catch end
            end
            rethrow()
        end
    end
end

mutable struct TreeSitterBackend <: AbstractProjectDataBackend
    worker::BackendWorker
end
mutable struct CodeGraphBackend <: AbstractProjectDataBackend
    worker::BackendWorker
    initialized::Bool
end
mutable struct GoASTBackend <: AbstractProjectDataBackend
    worker::BackendWorker
end
function parser_command()
    python=get(ENV,"SHENSCOPE_PARSER_PYTHON","/workspace/toolchains/codegraph-venv/bin/python")
    [python,joinpath(dirname(@__DIR__),"..","scripts","backends","parser_worker.py")]
end
TreeSitterBackend()=TreeSitterBackend(BackendWorker(parser_command()))
CodeGraphBackend()=CodeGraphBackend(BackendWorker(parser_command()),false)
GoASTBackend()=GoASTBackend(BackendWorker([get(ENV,"SHENSCOPE_GO_HELPER","/workspace/toolchains/shenscope-go-ast")]))
backend_capabilities(::TreeSitterBackend)=BackendCapabilities(;name="tree_sitter",languages=["python","go","javascript","typescript","rust","java","julia"],diagnostics=true)
backend_capabilities(::CodeGraphBackend)=BackendCapabilities(;name="codegraph",languages=["python","go","javascript","typescript","rust","java"],inheritance=true,diagnostics=true,global_relink=true)
backend_capabilities(::GoASTBackend)=BackendCapabilities(;name="go_ast",languages=["go"],diagnostics=true)
backend_prepare!(backend::AbstractProjectDataBackend,ctx::RuntimeContext)=nothing
backend_prepare!(backend::Union{TreeSitterBackend,GoASTBackend},ctx::RuntimeContext)=worker_start!(backend.worker,ctx)
function backend_prepare!(backend::CodeGraphBackend,ctx::RuntimeContext)
    (backend.worker.process===nothing || process_exited(backend.worker.process)) && (backend.initialized=false)
    worker_start!(backend.worker,ctx)
end
backend_close!(backend::Union{TreeSitterBackend,CodeGraphBackend,GoASTBackend})=worker_close!(backend.worker)

function syntax_facts(document::AbstractDict)
    path=document["path"];language=Symbol(document["language"])
    root=symbol_id(path,"file");source_range=SourceRange(path,1,1)
    symbols=CodeSymbol[CodeSymbol(root,:file,basename(path),path,source_range,language,Dict{String,Any}())]
    by_key=Dict("__file__"=>root);occurrences=Dict{String,Int}();relations=Relation[]
    for raw in document["symbols"]
        identity=canonical([raw["kind"],raw["qualified_name"],get(raw,"signature","")]);ordinal=get(occurrences,identity,0);occurrences[identity]=ordinal+1
        id=symbol_id(path,identity,ordinal);by_key[raw["key"]]=id
        range=SourceRange(path,raw["start_line"],raw["end_line"];start_column=get(raw,"start_column",1),end_column=get(raw,"end_column",1))
        push!(symbols,CodeSymbol(id,Symbol(raw["kind"]),raw["name"],raw["qualified_name"],range,language,
            Dict{String,Any}("signature"=>get(raw,"signature",""),"semantic"=>false)))
        push!(relations,Relation(root,id,:contains,range;provenance="parser_declaration"))
    end
    for raw in get(document,"edges",Any[])
        push!(relations,Relation(by_key[raw["src"]],by_key[raw["dst"]],Symbol(raw["kind"]),
            SourceRange(path,raw["start_line"],raw["end_line"]);provenance="parser_structure"))
    end
    references=CallReference[]
    for raw in document["references"]
        src=get(by_key,raw["src"],root)
        push!(references,CallReference(src,raw["name"],SourceRange(path,raw["start_line"],raw["end_line"];
            start_column=get(raw,"start_column",1),end_column=get(raw,"end_column",1)),raw["qualified"]))
    end
    FileFacts(path,document["sha256"],symbols,relations,references,Dict{String,Any}[])
end
function extract_files(backend::Union{TreeSitterBackend,GoASTBackend},documents,ctx;all_documents=documents,deleted=String[],full=false)
    raw=worker_request(backend.worker,"syntax",Dict("documents"=>documents),ctx)
    syntax_facts.(raw)
end

nonnull(d,key,default)=get(d,key,nothing)===nothing ? default : d[key]
function codegraph_facts(raw::AbstractDict,documents,ctx::RuntimeContext)
    by_path=Dict(d["path"]=>d for d in documents);occurrences=Dict{String,Int}()
    node_symbols=Dict{String,CodeSymbol}();buckets=Dict{String,Vector{CodeSymbol}}();edges=Dict{String,Vector{Relation}}()
    key(value)=canonical(value)
    for node in sort!(raw["nodes"];by=n->(nonnull(n,"path",""),nonnull(n,"line_number",0),nonnull(n,"occurrence_index",0),n["_LABEL"]))
        label=node["_LABEL"];label in ("Repository","Directory") && continue
        absolute=get(node,"path",nothing);absolute===nothing && continue
        relative=replace(relpath(absolute,ctx.root),'\\'=>'/')
        haskey(by_path,relative) || continue
        workspace_path(ctx.root,relative)
        kind=Symbol(lowercase(label));name=nonnull(node,"name",basename(relative))
        line=max(1,nonnull(node,"line_number",nonnull(node,"function_line_number",1)))
        ending=max(line,nonnull(node,"end_line",line));context=nonnull(node,"context","")
        qualified=isempty(context) ? name : context*"."*name
        identity=canonical([relative,String(kind),qualified,nonnull(node,"args",Any[]),nonnull(node,"arg_types",Any[])])
        ordinal=get(occurrences,identity,0);occurrences[identity]=ordinal+1
        id=symbol_id(identity,ordinal)
        metadata=Dict{String,Any}("backend"=>"codegraphcontext","semantic"=>false)
        for field in ("cyclomatic_complexity","args","docstring","visibility","modifiers","context_type")
            haskey(node,field) && (metadata[field]=node[field])
        end
        symbol=CodeSymbol(id,kind,name,qualified,SourceRange(relative,line,ending),Symbol(by_path[relative]["language"]),metadata)
        node_symbols[key(node["_ID"])]=symbol;push!(get!(Vector{CodeSymbol},buckets,relative),symbol)
    end
    for edge in raw["edges"]
        src=get(node_symbols,key(edge["_SRC"]),nothing);dst=get(node_symbols,key(edge["_DST"]),nothing)
        (src===nothing || dst===nothing) && continue
        owner=src.location.file;line=max(1,nonnull(edge,"line_number",src.location.start_line))
        relation=Relation(src.id,dst.id,Symbol(lowercase(edge["_LABEL"])),SourceRange(owner,line,line);
            confidence=nonnull(edge,"confidence",edge["_LABEL"]=="CALLS" ? 0.5 : 1.0),
            provenance="codegraphcontext:"*string(nonnull(edge,"resolution_tier","syntax")))
        push!(get!(Vector{Relation},edges,owner),relation)
    end
    [FileFacts(path,d["sha256"],get(buckets,path,CodeSymbol[]),get(edges,path,Relation[]),CallReference[],Dict{String,Any}[])
        for (path,d) in sort!(collect(by_path);by=first)]
end
function extract_files(backend::CodeGraphBackend,documents,ctx;all_documents=documents,deleted=String[],full=false)
    initialize=!backend.initialized
    complete=source_documents(ctx,project_paths(ctx,backend_capabilities(backend)))
    inputs=initialize || full ? complete : documents
    database=joinpath(ctx.state_dir,"projects",digest(ctx.root),"codegraph-sdk")
    result=worker_request(backend.worker,"codegraph",Dict("root"=>ctx.root,"state"=>database,"documents"=>inputs,
        "deleted"=>deleted,"full"=>initialize || full),ctx)
    backend.initialized=true
    codegraph_facts(result,complete,ctx)
end
