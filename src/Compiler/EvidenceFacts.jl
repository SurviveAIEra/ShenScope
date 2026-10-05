function runtime_evidence_source_context(ctx::RuntimeContext,snapshot::RuntimeSourceSnapshot)
    RuntimeContext(snapshot.root;session_id=ctx.session_id,state_dir=ctx.state_dir,cancellation=ctx.cancellation,
        budget=ctx.budget,permissions=ctx.permissions,sandbox=ctx.sandbox,approve=ctx.approve,sink=ctx.sink)
end

function runtime_evidence_read_facts(rows,snapshot::RuntimeSourceSnapshot,ctx::RuntimeContext,limits::RuntimeEvidenceLimits)
    paths=sort!(unique(String[row["source"]["file"] for row in rows if row["source"]["file"]!==nothing]))
    length(paths)<=limits.files || throw(ShenScopeError(:capacity,"Runtime source fact selection exceeds file capacity"))
    source_context=runtime_evidence_source_context(ctx,snapshot)
    documents=Dict{String,Any}[];total=0
    for path in paths
        compiler_source_checkpoint(ctx,snapshot.root)
        source=read_scoped_text(source_context,snapshot.root,path,JULIA_SYNTAX_MAX_SOURCE;authorized=true,
            tool="runtime.diagnostics",size_error=:capacity,reason="Parse hash-verified installed Core declaration facts")
        recorded=only(file for file in snapshot.files if file.path==path)
        digest(source)==recorded.sha256 && ncodeunits(source)==recorded.bytes ||
            throw(ShenScopeError(:conflict,"Core source changed before declaration extraction"))
        total+=ncodeunits(source)
        total<=limits.read_bytes || throw(ShenScopeError(:capacity,"Runtime declaration source exceeds read capacity"))
        push!(documents,Dict("path"=>path,"language"=>"julia","source"=>source,"sha256"=>recorded.sha256))
    end
    facts=extract_files(JuliaSyntaxBackend(),documents,source_context)
    for (file,document) in zip(facts,documents)
        get(file.metadata,"parse_complete",false)===true && isempty(file.diagnostics) ||
            throw(ShenScopeError(:diagnostics,"Runtime declaration parsing is incomplete for "*file.path))
        map=SourceMap(file.path,document["source"])
        all(row->row["source"]["file"]!=file.path || 1<=row["source"]["line"]<=length(map.starts),rows) ||
            throw(ShenScopeError(:conflict,"A runtime source position is beyond its verified file"))
        for symbol in file.symbols;source_range_indices(map,symbol.location);end
    end
    bounded_canonical_json(facts_dict.(facts);maximum=limits.retained_bytes)
    facts
end

function runtime_evidence_declarations(facts::AbstractVector{FileFacts},snapshot::RuntimeSourceSnapshot,
        provider::String,work::RuntimeEvidenceWork)
    result=RuntimeEvidenceDeclaration[];seen=Set{String}()
    for file in facts
        source=findfirst(item->item.path==file.path,snapshot.files)
        source!==nothing && snapshot.files[source].sha256==file.sha256 ||
            throw(ShenScopeError(:conflict,"Declaration facts disagree with the runtime source inventory"))
        for symbol in file.symbols
            runtime_evidence_tick!(work)
            symbol.location.file==file.path || throw(ShenScopeError(:diagnostics,"A runtime declaration has another source owner"))
            symbol.kind in (:method,:function) || continue
            length(result)<work.limits.declarations || throw(ShenScopeError(:capacity,"Runtime declaration count exceeds capacity"))
            key=evidence_symbol_key(provider,symbol.id)
            key in seen && throw(ShenScopeError(:diagnostics,"Runtime declaration identities must be unique"))
            push!(seen,key);push!(result,RuntimeEvidenceDeclaration(key,provider,deepcopy(symbol),file.sha256))
        end
    end
    sort!(result;by=value->(value.symbol.location.file,value.symbol.location.start_line,
        value.symbol.location.end_line,value.key))
    result
end

function runtime_evidence_intervals(declarations::AbstractVector{RuntimeEvidenceDeclaration})
    grouped=Dict{String,Vector{RuntimeEvidenceDeclaration}}()
    for item in declarations;push!(get!(Vector{RuntimeEvidenceDeclaration},grouped,item.symbol.location.file),item);end
    indexes=Dict{String,RuntimeEvidenceIntervals}()
    for (path,items) in grouped
        sort!(items;by=item->(item.symbol.location.start_line,item.symbol.location.end_line,item.key))
        starts=[item.symbol.location.start_line for item in items]
        ends=accumulate(max,[item.symbol.location.end_line for item in items])
        indexes[path]=RuntimeEvidenceIntervals(items,starts,ends)
    end
    indexes
end

function runtime_evidence_candidates(row::AbstractDict,indexes,work::RuntimeEvidenceWork)
    source=row["source"];source["file"]===nothing && return RuntimeEvidenceDeclaration[]
    index=get(indexes,source["file"],nothing);index===nothing && return RuntimeEvidenceDeclaration[]
    line=source["line"];cursor=searchsortedlast(index.starts,line);result=RuntimeEvidenceDeclaration[]
    while cursor>0 && index.prefix_ends[cursor]>=line
        runtime_evidence_tick!(work)
        declaration=index.declarations[cursor];range=declaration.symbol.location
        if range.end_line>=line
            declaration.sha256==source["source_sha256"] || throw(ShenScopeError(:conflict,"Runtime join source hashes differ"))
            length(result)<work.limits.candidates || throw(ShenScopeError(:capacity,"Runtime source position has too many declaration candidates"))
            push!(result,declaration)
        end
        cursor-=1
    end
    sort!(result;by=value->value.key)
end
