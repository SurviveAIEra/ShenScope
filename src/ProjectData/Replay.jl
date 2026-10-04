mutable struct ProjectReplay
    state::ProjectState
    pending::Dict{String,Union{Nothing,FileFacts}}
    revision::Union{Nothing,Int}
    metadata::Dict{String,Any}
    snapshot::Union{Nothing,Dict{String,Any}}
    committed_records::Int
    committed_bytes::Int
end
ProjectReplay(state::ProjectState)=ProjectReplay(state,Dict{String,Union{Nothing,FileFacts}}(),nothing,
    Dict{String,Any}(),nothing,0,0)

function project_record_fields(record,required::Tuple,optional::Tuple=())
    record isa AbstractDict && all(key->haskey(record,key),required) &&
        all(key->key in required || key in optional,keys(record)) ||
        throw(ShenScopeError(:storage,"Invalid project journal record fields"))
end

function project_record_integer(value;minimum=0,maximum=typemax(Int))
    value isa Integer && !(value isa Bool) && minimum<=value<=maximum ||
        throw(ShenScopeError(:storage,"Invalid project journal integer"))
    Int(value)
end

function project_replay_begin!(replay::ProjectReplay,record,sequence::Int;snapshot=false)
    required=snapshot ? ("kind","format","revision","root","backend","metadata","files","fingerprint","generation") :
        ("kind","revision","root","backend")
    project_record_fields(record,required,snapshot ? () : ("metadata",))
    state=replay.state
    replay.revision===nothing && record["root"]==state.root && record["backend"]==state.backend ||
        throw(ShenScopeError(:storage,"Invalid project transaction owner or boundary"))
    revision=project_record_integer(record["revision"])
    if snapshot
        sequence==1 && isempty(state.files) && state.revision==0 && record["format"]===1 ||
            throw(ShenScopeError(:storage,"Project snapshot must be the first supported transaction"))
        project_record_integer(record["files"];maximum=10000)
        record["fingerprint"] isa AbstractString && occursin(r"^[a-f0-9]{64}$",record["fingerprint"]) &&
            record["generation"] isa AbstractString && occursin(r"^[a-f0-9-]{36}$",record["generation"]) ||
            throw(ShenScopeError(:storage,"Invalid project snapshot identity"))
        replay.snapshot=Dict{String,Any}(record)
    else
        revision==state.revision+1 || throw(ShenScopeError(:storage,"Project transaction revision mismatch"))
        replay.snapshot=nothing
    end
    replay.revision=revision;empty!(replay.pending)
    replay.metadata=project_metadata(get(record,"metadata",state.metadata))
end

function project_replay_file!(replay::ProjectReplay,record)
    project_record_fields(record,("kind","path","facts"))
    path=record["path"]
    replay.revision!==nothing && path isa AbstractString && isvalid(path) &&
        ncodeunits(path)<=4096 && !haskey(replay.pending,path) && length(replay.pending)<(replay.snapshot===nothing ? 20000 : 10000) ||
        throw(ShenScopeError(:storage,"Invalid project file boundary, identity or capacity"))
    facts=record["facts"]
    replay.snapshot!==nothing && facts===nothing && throw(ShenScopeError(:storage,"Snapshots may not contain file tombstones"))
    normalized=try
        facts===nothing ? nothing : facts_from(facts)
    catch error
        error isa ShenScopeError && rethrow()
        throw(ShenScopeError(:storage,"Project file facts have invalid types"))
    end
    replay.pending[String(path)]=normalized
end

function project_replay_commit!(replay::ProjectReplay,record,sequence::Int,ending::Int,ctx::RuntimeContext)
    project_record_fields(record,("kind","revision","files"))
    replay.revision!==nothing && project_record_integer(record["revision"])==replay.revision &&
        project_record_integer(record["files"];maximum=replay.snapshot===nothing ? 20000 : 10000)==length(replay.pending) ||
        throw(ShenScopeError(:storage,"Invalid project commit boundary"))
    if replay.snapshot!==nothing
        header=replay.snapshot
        length(replay.pending)==header["files"] || throw(ShenScopeError(:storage,"Project snapshot file count mismatch"))
        files=Dict{String,FileFacts}(path=>facts for (path,facts) in replay.pending)
        fingerprint=project_fingerprint(files,replay.metadata,replay.state.root,replay.state.backend,replay.revision;
            checkpoint=()->project_storage_checkpoint(ctx))
        fingerprint==header["fingerprint"] || throw(ShenScopeError(:storage,"Project snapshot fingerprint mismatch"))
    end
    validate_facts(replay.state,replay.pending)
    install_facts!(replay.state,replay.pending)
    replay.state.revision=replay.revision;replay.state.metadata=replay.metadata
    replay.revision=nothing;replay.snapshot=nothing;empty!(replay.pending)
    replay.committed_records=sequence;replay.committed_bytes=ending
end

function project_replay_record!(replay::ProjectReplay,record,sequence::Int,ending::Int,ctx::RuntimeContext)
    kind=get(record,"kind",nothing)
    if kind=="project_begin";project_replay_begin!(replay,record,sequence)
    elseif kind=="project_snapshot";project_replay_begin!(replay,record,sequence;snapshot=true)
    elseif kind=="project_file";project_replay_file!(replay,record)
    elseif kind=="project_commit";project_replay_commit!(replay,record,sequence,ending,ctx)
    else;throw(ShenScopeError(:storage,"Unknown project journal record"));end
end

function replay_project!(state::ProjectState,ctx::RuntimeContext)
    project_journal_scope(state,ctx)
    store_lock(state.journal.path) do
        replay=ProjectReplay(state)
        walk_journal(state.journal;maximum_bytes=MAX_PROJECT_JOURNAL_BYTES,
            checkpoint=()->project_storage_checkpoint(ctx)) do record,sequence,ending
            project_replay_record!(replay,record,sequence,ending,ctx)
        end
        replay.snapshot===nothing || throw(ShenScopeError(:storage,"Initial project snapshot is incomplete; refusing destructive recovery"))
        project_storage_checkpoint(ctx)
        identity=journal_file_identity(state.journal.path)
        if identity!==nothing && identity.bytes>replay.committed_bytes
            authorize!(ctx,:persistence,"project.recover",state.journal.path;
                reason="Discard the incomplete tail of a derived project index")
            project_storage_checkpoint(ctx)
            identity==journal_file_identity(state.journal.path) ||
                throw(ShenScopeError(:conflict,"Project cache changed during recovery approval"))
            for (category,target) in ((:read,ctx.root),(:persistence,state.journal.path))
                permission_decision(ctx.permissions,PermissionRequest("project-recovery",category,"project.recover",target,"Recover project index"))!=Deny ||
                    throw(ShenScopeError(:permission,"Project recovery permission was denied"))
            end
            truncate_journal!(state.journal,replay.committed_bytes)
        end
        state.journal_sequence=replay.committed_records
        state.journal_identity=journal_file_identity(state.journal.path)
        state.journal_bytes=state.journal_identity===nothing ? 0 : state.journal_identity.bytes
    end
    state
end
