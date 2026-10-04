function evidence_selected_paths(state::ProjectState,paths::Vector{String})
    isempty(paths) ? sort!(collect(keys(state.files))) : sort!([path for path in paths if haskey(state.files,path)])
end

function evidence_source_capture(state::ProjectState,paths::Vector{String},ctx::RuntimeContext,
        limits::EvidenceLimits; expected_revision=nothing)
    state.root==ctx.root || throw(ShenScopeError(:permission,"An evidence source belongs to another workspace"))
    project_journal_scope(state,ctx)
    lock(state.mutex) do
        evidence_checkpoint(ctx)
        expected_revision===nothing || state.revision==expected_revision ||
            throw(ShenScopeError(:conflict,"An evidence source revision changed"))
        project_verify_query_config(state,ctx)
        selected=evidence_selected_paths(state,paths)
        length(selected)<=PROJECT_EVIDENCE_MAX_FILES ||
            throw(ShenScopeError(:capacity,"Evidence file selection exceeds capacity"))
        files=Dict{String,String}();symbols=Dict{String,EvidenceSymbol}();relations=Dict{String,EvidenceRelation}()
        bytes=0
        for path in selected
            evidence_checkpoint(ctx)
            workspace_path(ctx.root,path)
            facts=state.files[path];files[path]=facts.sha256
            for symbol in facts.symbols
                length(symbols)%128==0 && evidence_checkpoint(ctx)
                length(symbols)<limits.symbols || throw(ShenScopeError(:capacity,"Evidence symbol selection exceeds capacity"))
                symbol.location.file==path || throw(ShenScopeError(:storage,"An evidence declaration has an invalid owner"))
                key=evidence_symbol_key(state.backend,symbol.id)
                haskey(symbols,key) && throw(ShenScopeError(:storage,"Duplicate evidence declaration identity"))
                value=EvidenceSymbol(key,state.backend,state.revision,deepcopy(symbol),facts.sha256)
                bytes=evidence_charge_bytes(bytes,evidence_symbol_dict(value),limits);symbols[key]=value
            end
        end
        for (key,value) in symbols
            evidence_checkpoint(ctx)
            for native in sort!(collect(get(state.forward,value.symbol.id,Set{String}())))
                relation=state.relations[native]
                dst=evidence_symbol_key(state.backend,relation.dst)
                haskey(symbols,dst) || continue
                length(relations)<limits.relations || throw(ShenScopeError(:capacity,"Evidence relation selection exceeds capacity"))
                sha=get(files,relation.location.file,nothing)
                sha===nothing && throw(ShenScopeError(:storage,"An evidence relation has no selected source owner"))
                id=evidence_relation_key(state.backend,native)
                item=EvidenceRelation(id,state.backend,state.revision,deepcopy(relation),key,dst,sha)
                bytes=evidence_charge_bytes(bytes,evidence_relation_dict(item),limits);relations[id]=item
            end
        end
        selection=digest(canonical(Dict("files"=>files,
            "symbols"=>[evidence_symbol_dict(symbols[id]) for id in sort!(collect(keys(symbols)))],
            "relations"=>[evidence_relation_dict(relations[id]) for id in sort!(collect(keys(relations)))])))
        stamp=EvidenceSourceStamp(state.backend,state.revision,deepcopy(state.capabilities),files,selection)
        (stamp=stamp,symbols=symbols,relations=relations,bytes=bytes)
    end
end

function evidence_merge_files!(files::Dict{String,String},source::EvidenceSourceStamp)
    for (path,sha) in source.files
        old=get(files,path,nothing)
        old===nothing || old==sha || throw(ShenScopeError(:evidence_conflict,
            "Evidence backends contain different source versions for "*path*"; refresh the indexes"))
        files[path]=sha
    end
    length(files)<=PROJECT_EVIDENCE_MAX_FILES || throw(ShenScopeError(:capacity,"Combined evidence file limit reached"))
end

function project_evidence_snapshot(states::AbstractVector{ProjectState},arguments::AbstractDict,ctx::RuntimeContext;authorized=false)
    authorized || authorize!(ctx,:read,"project.evidence",ctx.root;reason="Combine versioned facts from indexed project backends")
    evidence_checkpoint(ctx)
    limits=evidence_limits(arguments);names=evidence_backend_names(arguments)
    length(states)<=limits.sources && length(states)==length(names) && sort!([state.backend for state in states])==names ||
        throw(ShenScopeError(:arguments,"Evidence source selection does not match its indexes"))
    action=get(arguments,"action","evidence_compare")
    paths=evidence_paths(arguments,ctx;key=action in ("evidence_impact","evidence_tests") ? "scope_paths" : "paths")
    expected=evidence_expected_revisions(arguments,names)
    symbols=Dict{String,EvidenceSymbol}();relations=Dict{String,EvidenceRelation}()
    files=Dict{String,String}();sources=EvidenceSourceStamp[];bytes=0
    for state in sort!(collect(states);by=state->state.backend)
        captured=evidence_source_capture(state,paths,ctx,limits;expected_revision=get(expected,state.backend,nothing))
        evidence_merge_files!(files,captured.stamp)
        length(symbols)+length(captured.symbols)<=limits.symbols &&
            length(relations)+length(captured.relations)<=limits.relations ||
            throw(ShenScopeError(:capacity,"Combined evidence graph exceeds capacity"))
        bytes+=captured.bytes
        bytes<=limits.bytes || throw(ShenScopeError(:capacity,"Combined evidence exceeds memory capacity"))
        merge!(symbols,captured.symbols);merge!(relations,captured.relations);push!(sources,captured.stamp)
    end
    isempty(paths) || all(path->haskey(files,path),paths) || throw(ShenScopeError(:analysis,"An evidence path is not indexed by any selected source"))
    forward=Dict{String,Vector{String}}();reverse=Dict{String,Vector{String}}()
    for id in sort!(collect(keys(relations)))
        relation=relations[id]
        push!(get!(Vector{String},forward,relation.src),id);push!(get!(Vector{String},reverse,relation.dst),id)
    end
    anchors,members=evidence_build_anchors(symbols,ctx)
    bytes=evidence_charge_bytes(bytes,Dict("sources"=>evidence_source_dict.(sources),"files"=>files,
        "anchors"=>[evidence_anchor_dict(anchors[id]) for id in sort!(collect(keys(anchors)))]),limits)
    fingerprint=digest(canonical(Dict("root"=>ctx.root,"sources"=>evidence_source_dict.(sources),
        "anchors"=>[evidence_anchor_dict(anchors[id]) for id in sort!(collect(keys(anchors)))])))
    snapshot=ProjectEvidenceSnapshot(ctx.root,sources,symbols,relations,forward,reverse,anchors,members,
        files,fingerprint,bytes,limits)
    evidence_verify_snapshot(snapshot,states,ctx)
    snapshot
end
