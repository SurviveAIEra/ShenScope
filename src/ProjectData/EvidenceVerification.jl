function evidence_verify_files(snapshot::ProjectEvidenceSnapshot,ctx::RuntimeContext)
    total=0
    ranges=Dict{String,Vector{SourceRange}}()
    for value in values(snapshot.symbols)
        push!(get!(Vector{SourceRange},ranges,value.symbol.location.file),value.symbol.location)
    end
    for value in values(snapshot.relations)
        push!(get!(Vector{SourceRange},ranges,value.relation.location.file),value.relation.location)
    end
    for path in sort!(collect(keys(snapshot.files)))
        evidence_checkpoint(ctx)
        absolute=workspace_path(ctx.root,path;must_exist=true)
        size=filesize(absolute)
        size<=8*1024*1024 && total+size<=PROJECT_EVIDENCE_MAX_READ_BYTES ||
            throw(ShenScopeError(:capacity,"Evidence source verification exceeds read capacity; select fewer paths"))
        source=read_scoped_text(ctx,ctx.root,absolute,8*1024*1024;authorized=true,
            tool="project.evidence",size_error=:capacity,encoding_error=:graph)
        total+=ncodeunits(source)
        total<=PROJECT_EVIDENCE_MAX_READ_BYTES || throw(ShenScopeError(:capacity,"Evidence source grew beyond verification capacity"))
        digest(source)==snapshot.files[path] || throw(ShenScopeError(:stale_index,
            "A combined evidence source changed; refresh its project indexes"))
        map=SourceMap(path,source)
        for (index,range) in enumerate(get(ranges,path,SourceRange[]))
            index%128==0 && evidence_checkpoint(ctx)
            source_range_indices(map,range)
        end
    end
    total
end

function evidence_verify_revisions(snapshot::ProjectEvidenceSnapshot,states,ctx::RuntimeContext)
    for stamp in snapshot.sources
        evidence_checkpoint(ctx)
        matches=[state for state in states if state.backend==stamp.backend]
        length(matches)==1 || throw(ShenScopeError(:conflict,"An evidence source was removed or duplicated"))
        state=only(matches)
        lock(state.mutex) do
            state.root==snapshot.root && state.revision==stamp.revision ||
                throw(ShenScopeError(:conflict,"An evidence source changed during analysis"))
            all(path->haskey(state.files,path) && state.files[path].sha256==stamp.files[path],keys(stamp.files)) ||
                throw(ShenScopeError(:conflict,"An evidence source selection changed"))
            project_verify_query_config(state,ctx)
        end
    end
end

function evidence_verify_snapshot(snapshot::ProjectEvidenceSnapshot,states,ctx::RuntimeContext)
    snapshot.root==ctx.root || throw(ShenScopeError(:permission,"Combined evidence belongs to another workspace"))
    evidence_verify_revisions(snapshot,states,ctx)
    evidence_verify_files(snapshot,ctx)
    evidence_verify_revisions(snapshot,states,ctx)
    evidence_checkpoint(ctx)
    nothing
end
