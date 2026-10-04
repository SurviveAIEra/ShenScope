function project_compaction_options(state::ProjectState;expected_revision=nothing,minimum_savings=1,force=false)
    expected_revision===nothing || project_record_integer(expected_revision)==state.revision ||
        throw(ShenScopeError(:conflict,"Project revision changed before compaction"))
    minimum_savings isa Integer && !(minimum_savings isa Bool) && 0<=minimum_savings<=MAX_PROJECT_JOURNAL_BYTES ||
        throw(ShenScopeError(:graph,"Invalid compaction savings threshold"))
    force isa Bool || throw(ShenScopeError(:graph,"Compaction force option must be Boolean"))
end

function project_compaction_permission(state::ProjectState,ctx::RuntimeContext)
    project_storage_checkpoint(ctx)
    for (category,target) in ((:read,ctx.root),(:persistence,state.journal.path))
        permission_decision(ctx.permissions,PermissionRequest("project-compact-current",category,
            "project.compact",target,"Compact derived project facts"))!=Deny ||
            throw(ShenScopeError(:permission,"Project compaction permission was denied before publication"))
    end
    project_journal_scope(state,ctx);verify_project_journal(state)
end

function project_snapshot_records(state::ProjectState,fingerprint::String,generation::String)
    header=Dict("kind"=>"project_snapshot","format"=>1,"root"=>state.root,"backend"=>state.backend,
        "revision"=>state.revision,"files"=>length(state.files),"metadata"=>project_metadata(state.metadata),
        "fingerprint"=>fingerprint,"generation"=>generation)
    files=(Dict("kind"=>"project_file","path"=>path,"facts"=>facts_dict(state.files[path]))
        for path in sort!(collect(keys(state.files))))
    commit=Dict("kind"=>"project_commit","revision"=>state.revision,"files"=>length(state.files))
    Iterators.flatten(((header,),files,(commit,)))
end

function compact_project!(state::ProjectState,ctx::RuntimeContext;expected_revision=nothing,minimum_savings=1,force=false)
    project_journal_scope(state,ctx)
    authorize!(ctx,:read,"project.compact",ctx.root;reason="Read current derived project facts")
    authorize!(ctx,:persistence,"project.compact",state.journal.path;
        reason="Atomically replace project index history with its latest verified snapshot")
    lock(state.mutex) do
        project_compaction_options(state;expected_revision,minimum_savings,force)
        project_compaction_permission(state,ctx)
        started=time();old_bytes=state.journal_bytes;generation=string(uuid4())
        current=Dict{String,Union{Nothing,FileFacts}}(path=>facts for (path,facts) in state.files)
        validate_facts(state,current)
        fingerprint=project_fingerprint(state;checkpoint=()->project_storage_checkpoint(ctx))
        records=project_snapshot_records(state,fingerprint,generation)
        result=store_lock(state.journal.path) do
            project_compaction_permission(state,ctx)
            reclaim_atomic_staging!(state.journal.path;minimum_age_seconds=0,
                checkpoint=()->project_compaction_permission(state,ctx))
            written=atomic_stream_write(state.journal.path;maximum_bytes=MAX_PROJECT_JOURNAL_BYTES,
                before_publish=(bytes,count)->begin
                    project_compaction_permission(state,ctx)
                    force || old_bytes-bytes>=minimum_savings
                end) do output
                count=0
                for record in records
                    project_storage_checkpoint(ctx);count+=1
                    write(output,journal_frame_text(record,count,state.journal.max_record_bytes))
                end
                count
            end
            if written.published
                identity=journal_file_identity(state.journal.path)
                identity!==nothing && identity.bytes==written.bytes ||
                    throw(ShenScopeError(:conflict,"Project snapshot changed immediately after publication"))
                state.journal_sequence=written.result
                state.journal_identity=identity;state.journal_bytes=identity.bytes
            end
            written
        end
        summary=Dict("backend"=>state.backend,"revision"=>state.revision,"compacted"=>result.published,
            "before_bytes"=>old_bytes,"after_bytes"=>state.journal_bytes,"saved_bytes"=>old_bytes-state.journal_bytes,
            "fingerprint"=>fingerprint,"files"=>length(state.files),"seconds"=>time()-started,
            "generation"=>result.published ? generation : nothing,
            "reason"=>result.published ? "latest_snapshot" : "insufficient_savings")
        emit!(ctx,:project_compacted,summary)
        summary
    end
end
