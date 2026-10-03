mutable struct ProjectState
    root::String
    backend::String
    capabilities::BackendCapabilities
    files::Dict{String,FileFacts}
    symbols::Dict{SymbolId,CodeSymbol}
    relations::Dict{String,Relation}
    forward::Dict{SymbolId,Set{String}}
    reverse::Dict{SymbolId,Set{String}}
    by_name::Dict{String,Set{SymbolId}}
    referenced_by::Dict{String,Set{String}}
    file_edges::Dict{String,Set{String}}
    revision::Int
    journal::Journal
    journal_bytes::Int
    journal_sequence::Int
    mutex::ReentrantLock
    metadata::Dict{String,Any}
end
function ProjectState(ctx::RuntimeContext,backend::AbstractProjectDataBackend)
    caps=backend_capabilities(backend)
    path=joinpath(ctx.state_dir,"projects",digest(ctx.root),digest(caps.name)*".jsonl")
    ProjectState(ctx.root,caps.name,caps,Dict{String,FileFacts}(),Dict{SymbolId,CodeSymbol}(),Dict{String,Relation}(),
        Dict{SymbolId,Set{String}}(),Dict{SymbolId,Set{String}}(),Dict{String,Set{SymbolId}}(),Dict{String,Set{String}}(),
        Dict{String,Set{String}}(),0,Journal(path),0,0,ReentrantLock(),Dict{String,Any}())
end
struct ProjectDelta
    revision::Int
    changed_files::Vector{String}
    relinked_files::Vector{String}
    added_symbols::Int
    removed_symbols::Int
    added_relations::Int
    removed_relations::Int
    timings::Dict{String,Float64}
end
function delta_dict(d::ProjectDelta)
    Dict("revision"=>d.revision,"changed_files"=>d.changed_files,"relinked_files"=>d.relinked_files,
        "added_symbols"=>d.added_symbols,"removed_symbols"=>d.removed_symbols,
        "added_relations"=>d.added_relations,"removed_relations"=>d.removed_relations,"timings"=>d.timings)
end

function remove_edge!(state::ProjectState,id::String)
    edge=pop!(state.relations,id,nothing);edge===nothing && return
    delete!(get(state.forward,edge.src,Set{String}()),id)
    delete!(get(state.reverse,edge.dst,Set{String}()),id)
    isempty(get(state.forward,edge.src,Set{String}())) && delete!(state.forward,edge.src)
    isempty(get(state.reverse,edge.dst,Set{String}())) && delete!(state.reverse,edge.dst)
end
function add_edge!(state::ProjectState,edge::Relation,owner::String)
    haskey(state.symbols,edge.src) && haskey(state.symbols,edge.dst) || throw(ShenScopeError(:graph,"Dangling graph relation"))
    state.relations[edge.id]=edge
    push!(get!(Set{String},state.forward,edge.src),edge.id)
    push!(get!(Set{String},state.reverse,edge.dst),edge.id)
    push!(get!(Set{String},state.file_edges,owner),edge.id)
end

function resolve_reference(state::ProjectState,ref::CallReference)
    candidates=get(state.by_name,ref.name,Set{SymbolId}())
    local_ids=[id for id in candidates if state.symbols[id].location.file==ref.location.file && state.symbols[id].kind in (:function,:method)]
    ids=isempty(local_ids) ? [id for id in candidates if state.symbols[id].kind in (:function,:method)] : local_ids
    # Qualified/dynamic calls require a compiler-aware backend. Name matching
    # may supply a candidate only for an unqualified unique declaration.
    ref.qualified || length(ids)!=1 ? nothing : Relation(ref.src,only(ids),:calls,ref.location;
        confidence=isempty(local_ids) ? 0.45 : 0.65,provenance="unique_syntax_candidate")
end

function install_facts!(state::ProjectState,changes::Dict{String,Union{Nothing,FileFacts}})
    touched_names=Set{String}();dirty=Set(keys(changes))
    for path in keys(changes)
        old=get(state.files,path,nothing);old===nothing && continue
        union!(touched_names,(s.name for s in old.symbols))
    end
    for facts in values(changes)
        facts===nothing || union!(touched_names,(s.name for s in facts.symbols))
    end
    for name in touched_names;union!(dirty,get(state.referenced_by,name,Set{String}()));end
    before_symbols=Set{SymbolId}();before_edges=Set{String}()
    for path in dirty
        union!(before_edges,get(state.file_edges,path,Set{String}()))
        for id in get(state.file_edges,path,Set{String}());remove_edge!(state,id);end
        delete!(state.file_edges,path)
    end
    for path in keys(changes)
        old=pop!(state.files,path,nothing);old===nothing && continue
        for symbol in old.symbols
            push!(before_symbols,symbol.id);delete!(state.symbols,symbol.id)
            bucket=get(state.by_name,symbol.name,Set{SymbolId}());delete!(bucket,symbol.id)
            isempty(bucket) && delete!(state.by_name,symbol.name)
        end
        for ref in old.references
            bucket=get(state.referenced_by,ref.name,Set{String}());delete!(bucket,path)
            isempty(bucket) && delete!(state.referenced_by,ref.name)
        end
    end
    after_symbols=Set{SymbolId}()
    for (path,facts) in changes
        facts===nothing && continue;state.files[path]=facts
        for symbol in facts.symbols
            state.symbols[symbol.id]=symbol;push!(after_symbols,symbol.id)
            push!(get!(Set{SymbolId},state.by_name,symbol.name),symbol.id)
        end
        for ref in facts.references;push!(get!(Set{String},state.referenced_by,ref.name),path);end
    end
    after_edges=Set{String}()
    for path in dirty
        facts=get(state.files,path,nothing);facts===nothing && continue
        for edge in facts.relations
            haskey(state.symbols,edge.src) && haskey(state.symbols,edge.dst) || continue
            add_edge!(state,edge,path);push!(after_edges,edge.id)
        end
        for ref in facts.references
            edge=resolve_reference(state,ref);edge===nothing && continue
            add_edge!(state,edge,path);push!(after_edges,edge.id)
        end
    end
    return sort!(collect(dirty)),length(setdiff(after_symbols,before_symbols)),length(setdiff(before_symbols,after_symbols)),
        length(setdiff(after_edges,before_edges)),length(setdiff(before_edges,after_edges))
end

const SOURCE_LANGUAGES=Dict(".py"=>"python",".go"=>"go",".ts"=>"typescript",".tsx"=>"tsx",
    ".js"=>"javascript",".jsx"=>"javascript",".rs"=>"rust",".java"=>"java",".jl"=>"julia")
const INDEX_IGNORES=Set([".git","node_modules","vendor","dist","build",".local",".venv","__pycache__","target"])
function project_paths(ctx::RuntimeContext,caps::BackendCapabilities;limit=10000)
    paths=String[]
    for (directory,dirs,files) in walkdir(ctx.root;follow_symlinks=false)
        filter!(d->!(d in INDEX_IGNORES) && !islink(joinpath(directory,d)),dirs)
        for file in files
            path=joinpath(directory,file);islink(path) && continue
            get(SOURCE_LANGUAGES,lowercase(splitext(file)[2]),"") in caps.languages || continue
            relative=replace(relpath(path,ctx.root),'\\'=>'/')
            workspace_path(ctx.root,relative);push!(paths,relative)
            length(paths)<=limit || throw(ShenScopeError(:graph,"Project file limit reached"))
        end
    end
    sort!(paths)
end
function source_documents(ctx::RuntimeContext,paths::AbstractVector; maximum_bytes=32*1024*1024)
    documents=Dict{String,Any}[]
    total=0
    length(paths)<=10000 || throw(ShenScopeError(:graph,"Changed file limit reached"))
    for path in sort!(unique(String.(paths)))
        check_cancelled(ctx.cancellation);absolute=workspace_path(ctx.root,path)
        !isfile(absolute) && continue
        filesize(absolute)<=8*1024*1024 || throw(ShenScopeError(:graph,"Source file exceeds limit"))
        total+filesize(absolute)<=maximum_bytes || throw(ShenScopeError(:graph,"Source snapshot exceeds aggregate capacity"))
        text=read_scoped_text(ctx,ctx.root,absolute,8*1024*1024;authorized=true,tool="project.index",size_error=:graph,encoding_error=:graph)
        total+=ncodeunits(text)
        total<=maximum_bytes || throw(ShenScopeError(:graph,"Source snapshot changed beyond aggregate capacity"))
        push!(documents,Dict("path"=>replace(relpath(absolute,ctx.root),'\\'=>'/'),"source"=>text,"sha256"=>digest(text),
            "language"=>get(SOURCE_LANGUAGES,lowercase(splitext(path)[2]),"")))
    end
    documents
end

function validate_facts(state::ProjectState,changes::Dict{String,Union{Nothing,FileFacts}})
    existing(id)=haskey(state.symbols,id) && !haskey(changes,state.symbols[id].location.file)
    identities=Set{SymbolId}()
    for (path,facts) in changes
        replace(relpath(workspace_path(state.root,path),state.root),'\\'=>'/')==path || throw(ShenScopeError(:graph,"Noncanonical file fact path"))
        facts===nothing && continue
        path==facts.path && occursin(r"^[a-f0-9]{64}$",facts.sha256) || throw(ShenScopeError(:graph,"Invalid file facts"))
        length(facts.symbols)<=100000 && length(facts.relations)<=500000 || throw(ShenScopeError(:graph,"File graph exceeds limits"))
        for s in facts.symbols
            s.location.file==path && !(s.id in identities) && !existing(s.id) || throw(ShenScopeError(:graph,"Invalid or colliding symbol identity"))
            push!(identities,s.id)
        end
    end
    for facts in values(changes)
        facts===nothing && continue
        for edge in facts.relations
            (edge.src in identities || existing(edge.src)) && (edge.dst in identities || existing(edge.dst)) || throw(ShenScopeError(:graph,"Invalid relation endpoint"))
            edge.location.file==facts.path || throw(ShenScopeError(:graph,"Relation evidence escapes file owner"))
        end
        all(r->r.src in identities,facts.references) || throw(ShenScopeError(:graph,"Invalid reference source"))
        length(facts.occurrences)<=200000 && ncodeunits(canonical(facts.metadata))<=512*1024 ||
            throw(ShenScopeError(:graph,"Semantic facts exceed capacity"))
        for occurrence in facts.occurrences
            occurrence.location.file==facts.path && all(id->id in identities || existing(id),occurrence.targets) ||
                throw(ShenScopeError(:graph,"Semantic occurrence has a foreign range or missing target"))
        end
    end
end

const MAX_PROJECT_JOURNAL_BYTES=128*1024*1024
function persist_delta!(state::ProjectState,changes::Dict{String,Union{Nothing,FileFacts}};metadata=state.metadata)
    records=Dict{String,Any}[Dict("kind"=>"project_begin","revision"=>state.revision+1,"root"=>state.root,"backend"=>state.backend)]
    isempty(metadata) || (records[1]["metadata"]=project_metadata(metadata))
    for (path,facts) in sort!(collect(changes);by=first)
        push!(records,Dict("kind"=>"project_file","path"=>path,"facts"=>facts===nothing ? nothing : facts_dict(facts)))
    end
    push!(records,Dict("kind"=>"project_commit","revision"=>state.revision+1,"files"=>length(changes)))
    frames=String[]
    for (index,record) in enumerate(records)
        frame=canonical(Dict("schema"=>1,"sequence"=>state.journal_sequence+index,"record"=>record,"sha256"=>digest(canonical(record))))*"\n"
        ncodeunits(frame)<=state.journal.max_record_bytes || throw(ShenScopeError(:graph,"Graph persistence record exceeds limit"))
        push!(frames,frame)
    end
    state.journal_bytes+sum(ncodeunits,frames)<=MAX_PROJECT_JOURNAL_BYTES ||
        throw(ShenScopeError(:graph,"Project cache limit reached; use a new explicit state directory"))
    store_lock(state.journal.path) do
        observed=isfile(state.journal.path) ? filesize(state.journal.path) : 0
        observed==state.journal_bytes || throw(ShenScopeError(:conflict,"Project cache changed; reload before updating"))
        mkpath(dirname(state.journal.path))
        open(state.journal.path,"a") do io
            chmod(state.journal.path,0o600);foreach(frame->write(io,frame),frames);flush(io);sync_file(io)
        end
    end
    state.journal_bytes+=sum(ncodeunits,frames);state.journal_sequence+=length(records)
end

function update!(backend::AbstractProjectDataBackend,state::ProjectState,paths::AbstractVector,ctx::RuntimeContext;full=false)
    state.root==ctx.root && state.backend==backend_capabilities(backend).name || throw(ShenScopeError(:graph,"Project/backend context mismatch"))
    authorize!(ctx,:read,"project.index",ctx.root;reason="Parse project source files")
    authorize!(ctx,:persistence,"project.index",state.journal.path;reason="Save incremental project facts")
    backend_prepare!(backend,ctx)
    paths=[replace(relpath(workspace_path(ctx.root,p),ctx.root),'\\'=>'/') for p in paths]
    lock(state.mutex) do
        started=time();inputs=project_inputs(backend,state,paths,ctx;full);scan=time()-started
        documents=inputs.documents;selected=inputs.selected;deleted=inputs.removed
        metadata_changed=canonical(inputs.metadata)!=canonical(state.metadata)
        isempty(selected) && isempty(deleted) && !metadata_changed && return ProjectDelta(state.revision,String[],String[],0,0,0,0,Dict("scan"=>scan,"total"=>time()-started))
        parse_started=time();facts=project_extract_files(backend,inputs,ctx;full)
        parse_seconds=time()-parse_started
        deleted=project_removed_files(backend,state,inputs,facts)
        changes=Dict{String,Union{Nothing,FileFacts}}(path=>nothing for path in unique(deleted))
        for fact in facts
            old=get(state.files,fact.path,nothing)
            old===nothing || canonical(facts_dict(old))!=canonical(facts_dict(fact)) || continue
            changes[fact.path]=fact
        end
        # Read the exact source again before committing, including files a
        # backend re-read during global resolution. Concurrent edits abort.
        for (path,fact) in changes
            if fact===nothing
                project_verify_removed(backend,inputs,path,ctx)
                continue
            end
            absolute=workspace_path(ctx.root,path)
            isfile(absolute) && digest(read_scoped_text(ctx,ctx.root,absolute,8*1024*1024;authorized=true,
                tool="project.index",size_error=:graph,encoding_error=:graph))==fact.sha256 ||
                throw(ShenScopeError(:conflict,"Source changed during graph extraction"))
        end
        project_verify_inputs(backend,inputs,ctx)
        isempty(changes) && !metadata_changed && return ProjectDelta(state.revision,String[],String[],0,0,0,0,Dict("scan"=>scan,"extract"=>parse_seconds,"total"=>time()-started))
        check_cancelled(ctx.cancellation);validate_facts(state,changes)
        for (category,target) in ((:read,ctx.root),(:persistence,state.journal.path))
            permission_decision(ctx.permissions,PermissionRequest("project-commit",category,"project.index",target,"Commit project facts"))!=Deny ||
                throw(ShenScopeError(:permission,"Project permission changed before commit"))
        end
        lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
        persisted=time();persist_delta!(state,changes;metadata=inputs.metadata);persist_seconds=time()-persisted
        applied=time();dirty,added,removed,added_edges,removed_edges=install_facts!(state,changes);state.revision+=1;state.metadata=deepcopy(inputs.metadata)
        delta=ProjectDelta(state.revision,sort!(collect(keys(changes))),dirty,added,removed,added_edges,removed_edges,
            Dict("scan"=>scan,"extract"=>parse_seconds,"persist"=>persist_seconds,"apply"=>time()-applied,"total"=>time()-started))
        emit!(ctx,:project_updated,delta_dict(delta));delta
    end
end
function build!(backend::AbstractProjectDataBackend,ctx::RuntimeContext)
    state=ProjectState(ctx,backend)
    isfile(state.journal.path) && (state=load_project(backend,ctx))
    update!(backend,state,project_paths(ctx,state.capabilities),ctx;full=true);state
end

function load_project(backend::AbstractProjectDataBackend,ctx::RuntimeContext)
    state=ProjectState(ctx,backend)
    store_lock(state.journal.path) do
        isfile(state.journal.path) && filesize(state.journal.path)>MAX_PROJECT_JOURNAL_BYTES &&
            throw(ShenScopeError(:graph,"Project cache exceeds the supported size limit"))
        records=journal_records(state.journal;repair_tail=true)
        pending=Dict{String,Union{Nothing,FileFacts}}();target=0;committed=0;metadata=Dict{String,Any}()
        for (index,record) in enumerate(records)
            kind=record["kind"]
            if kind=="project_begin"
                target==0 && record["root"]==ctx.root && record["backend"]==state.backend && record["revision"]==state.revision+1 ||
                    throw(ShenScopeError(:storage,"Invalid project transaction header"))
                target=record["revision"];empty!(pending);metadata=project_metadata(get(record,"metadata",state.metadata))
            elseif kind=="project_file"
                target!=0 && !haskey(pending,record["path"]) || throw(ShenScopeError(:storage,"Invalid project file record"))
                pending[record["path"]]=record["facts"]===nothing ? nothing : facts_from(record["facts"])
            elseif kind=="project_commit"
                target!=0 && record["revision"]==target && record["files"]==length(pending) || throw(ShenScopeError(:storage,"Invalid project commit"))
                validate_facts(state,pending);install_facts!(state,pending);state.revision=target;state.metadata=metadata;target=0;committed=index
            else;throw(ShenScopeError(:storage,"Unknown project record"));end
        end
        # Incomplete transactions are not visible. Reframe only on recovery,
        # never as a routine incremental update or repository backup.
        committed<length(records) && atomic_write(state.journal.path,journal_frames(records[1:committed]))
        state.journal_sequence=committed;state.journal_bytes=isfile(state.journal.path) ? filesize(state.journal.path) : 0
    end
    state
end
function graph_snapshot(state::ProjectState)
    lock(state.mutex) do
        Dict("symbols"=>sort!(symbol_dict.(collect(values(state.symbols)));by=x->x["id"]),
            "relations"=>sort!(relation_dict.(collect(values(state.relations)));by=x->x["id"]))
    end
end
