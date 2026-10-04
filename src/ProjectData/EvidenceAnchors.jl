function evidence_kind_family(kind::Symbol)
    kind in (:function,:method) && return :callable
    kind in (:class,:struct,:type) && return :type
    kind
end

function evidence_anchor_identity(value::EvidenceSymbol)
    symbol=value.symbol
    canonical([symbol.location.file,value.source_sha256,range_dict(symbol.location),
        String(evidence_kind_family(symbol.kind)),symbol.qualified_name])
end

function evidence_build_anchors(symbols::Dict{String,EvidenceSymbol},ctx::RuntimeContext)
    grouped=Dict{String,Vector{String}}()
    for id in sort!(collect(keys(symbols)))
        evidence_checkpoint(ctx)
        value=symbols[id]
        value.symbol.kind==:file && continue
        location=value.symbol.location
        location.start_line==location.end_line && location.start_column==location.end_column && continue
        key=evidence_anchor_identity(value)
        push!(get!(Vector{String},grouped,key),id)
    end
    anchors=Dict{String,EvidenceAnchor}();members=Dict{String,String}()
    for identity in sort!(collect(keys(grouped)))
        ids=sort!(grouped[identity]);length(ids)>=2 || continue
        backends=[symbols[id].backend for id in ids]
        length(unique(backends))>=2 || continue
        eligible=length(unique(backends))==length(backends)
        value=symbols[first(ids)];symbol=value.symbol
        id=digest(canonical(["anchor",identity]))[1:32]
        anchors[id]=EvidenceAnchor(id,ids,symbol.location.file,value.source_sha256,
            symbol.location,symbol.qualified_name,eligible)
        for member in ids;members[member]=id;end
    end
    anchors,members
end

function evidence_disagreements(snapshot::ProjectEvidenceSnapshot,ctx::RuntimeContext)
    result=Dict{String,Any}[]
    for id in sort!(collect(keys(snapshot.anchors)))
        evidence_checkpoint(ctx)
        anchor=snapshot.anchors[id]
        observations=Dict{String,Any}[]
        for key in anchor.members
            value=snapshot.symbols[key]
            outgoing=get(snapshot.forward,key,String[])
            push!(observations,Dict("key"=>key,"backend"=>value.backend,
                "provider_claims_semantic"=>get(value.symbol.metadata,"semantic",false),
                "recorded_kind"=>String(value.symbol.kind),"signature"=>get(value.symbol.metadata,"signature",nothing),
                "outgoing_relations"=>length(outgoing),
                "relation_kinds"=>sort!(unique([String(snapshot.relations[edge].relation.kind) for edge in outgoing]))))
        end
        signatures=unique([observation["signature"] for observation in observations if observation["signature"]!==nothing])
        counts=unique([observation["outgoing_relations"] for observation in observations])
        kinds=unique([canonical(observation["relation_kinds"]) for observation in observations])
        push!(result,Dict("anchor"=>evidence_anchor_dict(anchor),"observations"=>observations,
            "signature_text_disagreement"=>length(signatures)>1,"relation_count_disagreement"=>length(counts)>1,
            "relation_kind_disagreement"=>length(kinds)>1,"winner_selected"=>false,
            "limitations"=>["Different extraction granularity can explain disagreement; absence of an edge is not proof of absence."]))
    end
    result
end
