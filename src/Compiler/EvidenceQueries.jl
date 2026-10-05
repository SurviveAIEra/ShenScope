function runtime_evidence_verify_expected(snapshot::RuntimeEvidenceSnapshot,expected)
    expected===nothing || compiler_archive_hash(expected,"runtime evidence fingerprint")==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Runtime evidence changed; refresh the observation page"))
end

function runtime_evidence_query_parameters(;offset=0,limit=40,query="",observation_kind="all")
    offset=compiler_ir_integer(offset,"runtime evidence offset",0,40_000)
    limit=compiler_ir_integer(limit,"runtime evidence page limit",1,128)
    query isa String && isvalid(query) && ncodeunits(query)<=256 && !occursin('\0',query) ||
        throw(ShenScopeError(:diagnostics,"Invalid runtime evidence query"))
    observation_kind in RUNTIME_EVIDENCE_KINDS || throw(ShenScopeError(:diagnostics,"Unknown runtime observation kind"))
    (offset=offset,limit=limit,query=query,observation_kind=observation_kind)
end

function runtime_evidence_page(snapshot::RuntimeEvidenceSnapshot,ctx::RuntimeContext;offset=0,limit=40,
        query="",observation_kind="all",expected_evidence_sha256=nothing)
    options=runtime_evidence_query_parameters(;offset,limit,query,observation_kind)
    offset=options.offset;limit=options.limit;query=options.query
    runtime_evidence_verify_expected(snapshot,expected_evidence_sha256)
    compiler_source_checkpoint(ctx,snapshot.source.root)
    needle=lowercase(query)
    selected=Dict{String,Any}[]
    for (index,row) in enumerate(snapshot.rows)
        index%128==0 && compiler_source_checkpoint(ctx,snapshot.source.root)
        (observation_kind=="all" || row["kind"]==observation_kind) &&
            (isempty(needle) || occursin(needle,lowercase(canonical(row)))) && push!(selected,row)
    end
    total=length(selected)
    offset<=total || throw(ShenScopeError(:diagnostics,"Runtime evidence offset is past the selected observations"))
    stop=min(total,offset+limit)
    result=Dict("schema"=>RUNTIME_EVIDENCE_SCHEMA,"evidence_sha256"=>snapshot.fingerprint,"target"=>snapshot.target,
        "source_fingerprint"=>snapshot.source.fingerprint,"report_stamps"=>snapshot.report_stamps,
        "provider_stamps"=>snapshot.provider_stamps,"summary"=>snapshot.summary,"profile_summary"=>snapshot.profile_summary,
        "sampling_summary"=>snapshot.sampling_summary,
        "items"=>deepcopy(selected[offset+1:stop]),"offset"=>offset,"limit"=>limit,"total"=>total,
        "next_offset"=>stop<total ? stop : nothing,"query"=>query,"observation_kind"=>observation_kind,
        "producer_authenticated"=>false,"limitations"=>copy(RUNTIME_EVIDENCE_NOTES))
    bounded_canonical_json(result;maximum=2*1024^2)
    compiler_source_checkpoint(ctx,snapshot.source.root)
    result
end

function runtime_evidence_source(snapshot::RuntimeEvidenceSnapshot,key,ctx::RuntimeContext;
        expected_evidence_sha256,context_lines=4)
    compiler_archive_hash(expected_evidence_sha256,"required runtime evidence fingerprint")
    runtime_evidence_verify_expected(snapshot,expected_evidence_sha256)
    key=compiler_archive_hash(key,"runtime observation key")
    row=findfirst(item->item["key"]==key,snapshot.rows)
    row!==nothing || throw(ShenScopeError(:diagnostics,"Observation key is absent from selected runtime evidence"))
    observation=snapshot.rows[row];position=observation["source"]
    position["file"]!==nothing || throw(ShenScopeError(:diagnostics,"Selected runtime observation has no authored source position"))
    excerpt=compiler_source_excerpt_at(snapshot.source,ctx,position["file"],position["line"];
        report_sha256=observation["report_sha256"],context_lines,authorized=true)
    merge(excerpt,Dict("schema"=>"shenscope.runtime-evidence-source/1","evidence_sha256"=>snapshot.fingerprint,
        "observation_key"=>key,"observation_kind"=>observation["kind"],"join_status"=>observation["join_status"],
        "source_mapping"=>"retained observation line; declaration candidate association does not prove a runtime binding"))
end
