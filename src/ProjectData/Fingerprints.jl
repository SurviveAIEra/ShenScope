function project_fingerprint(files::AbstractDict,metadata::AbstractDict,root::String,backend::String,revision::Int;
        checkpoint=()->nothing)
    context=SHA.SHA2_256_CTX()
    header=canonical(Dict("format"=>1,"root"=>root,"backend"=>backend,"revision"=>revision,
        "metadata_sha256"=>digest(canonical(metadata))))*"\n"
    SHA.update!(context,codeunits(header))
    for path in sort!(collect(keys(files)))
        checkpoint()
        leaf=canonical(Dict("path"=>path,"facts_sha256"=>digest(canonical(facts_dict(files[path])))))*"\n"
        SHA.update!(context,codeunits(leaf))
    end
    bytes2hex(SHA.digest!(context))
end

function project_fingerprint(state::ProjectState;checkpoint=()->nothing)
    lock(state.mutex) do
        project_fingerprint(state.files,state.metadata,state.root,state.backend,state.revision;checkpoint)
    end
end

function project_storage_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    yield()
end

function project_journal_scope(state::ProjectState,ctx::RuntimeContext)
    state.root==ctx.root || throw(ShenScopeError(:permission,"Project storage belongs to another workspace"))
    expected=joinpath(ctx.state_dir,"projects",digest(ctx.root),digest(state.backend)*".jsonl")
    normpath(state.journal.path)==expected || throw(ShenScopeError(:permission,"Project journal belongs to another state directory"))
    directory=dirname(expected)
    if isdir(directory)
        realpath(directory)==directory || throw(ShenScopeError(:permission,"Project journal directory may not follow symlinks"))
    end
    journal_file_identity(expected)
    nothing
end

function verify_project_journal(state::ProjectState)
    identity=journal_file_identity(state.journal.path)
    identity==state.journal_identity && (identity===nothing ? state.journal_bytes==0 : identity.bytes==state.journal_bytes) ||
        throw(ShenScopeError(:conflict,"Project cache changed; reload before writing"))
    nothing
end
