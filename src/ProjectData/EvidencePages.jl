function evidence_page(snapshot::ProjectEvidenceSnapshot,items,arguments,ctx::RuntimeContext)
    limit=project_query_integer(arguments,"limit",50,1,1000)
    offset=project_query_integer(arguments,"offset",0,0,100000)
    selected=Dict{String,Any}[];bytes=0;total=0;full=false
    for item in items
        total+=1;total%128==0 && evidence_checkpoint(ctx)
        total<=offset && continue
        full && continue
        length(selected)>=limit && (full=true;continue)
        count=ncodeunits(canonical(item))
        count<=3*1024*1024 || throw(ShenScopeError(:capacity,"A combined evidence entry exceeds result capacity"))
        if bytes+count>3*1024*1024
            full=true;continue
        end
        bytes+=count;push!(selected,item)
    end
    evidence_checkpoint(ctx)
    Dict("fingerprint"=>snapshot.fingerprint,"sources"=>evidence_source_dict.(snapshot.sources),
        "total"=>total,"offset"=>offset,"next_offset"=>offset+length(selected)<total ? offset+length(selected) : nothing,
        "items"=>selected,"column_unit"=>"utf8_byte","source_bytes"=>snapshot.bytes,
        "revision_vector"=>Dict(source.backend=>source.revision for source in snapshot.sources),
        "atomic_multi_source_transaction"=>false)
end

function evidence_snapshot_status(snapshot::ProjectEvidenceSnapshot)
    Dict("fingerprint"=>snapshot.fingerprint,"sources"=>evidence_source_dict.(snapshot.sources),
        "symbols"=>length(snapshot.symbols),"relations"=>length(snapshot.relations),
        "files"=>length(snapshot.files),"anchors"=>length(snapshot.anchors),
        "eligible_bridges"=>count(anchor->anchor.eligible_bridge,values(snapshot.anchors)),
        "source_bytes"=>snapshot.bytes,"backend_private_schemas_exposed"=>false,
        "runtime_equivalence_confirmed"=>false)
end

function evidence_compare(snapshot::ProjectEvidenceSnapshot,arguments,ctx::RuntimeContext)
    result=evidence_page(snapshot,evidence_disagreements(snapshot,ctx),arguments,ctx)
    result["summary"]=evidence_snapshot_status(snapshot)
    result["limitations"]=["Exact source anchors preserve observations from every provider; no provider is automatically selected as truth.",
        "Declarations without identical ranges/names are not linked across sources.",
        "Duplicate declarations within a provider disable that anchor's bridge.",
        "Captured revision vectors are verified, but are not a transaction spanning every index and editor write."]
    result
end
