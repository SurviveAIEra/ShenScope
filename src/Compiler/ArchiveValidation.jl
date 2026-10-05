function compiler_archive_validate_execution(execution)
    compiler_ir_fields(execution,["separate_process","os_sandbox","timeout_seconds"],"archived helper execution")
    execution["separate_process"]===true && execution["os_sandbox"]===false ||
        throw(ShenScopeError(:diagnostics,"Compiler archive changed its recorded host-helper scope"))
    timeout=execution["timeout_seconds"]
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.1<=timeout<=120 ||
        throw(ShenScopeError(:diagnostics,"Invalid recorded compiler helper timeout"))
    nothing
end

function compiler_archive_validate_asset(value,store::CompilerArchiveStore;
        expected_report_sha256=nothing)
    compiler_ir_fields(value,["schema","owner","created_at","source","report","execution"],"archive asset")
    value["schema"]==COMPILER_ARCHIVE_SCHEMA && value["owner"]==compiler_archive_owner(store) ||
        throw(ShenScopeError(:permission,"Compiler archive evidence has a foreign owner or schema"))
    compiler_archive_timestamp(value["created_at"])
    source=value["source"]
    source isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler archive source inventory is invalid"))
    snapshot=runtime_source_from_view(source)
    snapshot.uuid==Base.PkgId(@__MODULE__).uuid || throw(ShenScopeError(:diagnostics,"Compiler archive belongs to a different Core package"))
    report=value["report"]
    report isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler archive report is invalid"))
    selected=compiler_target(compiler_ir_text(get(report,"target",nothing),"archived compiler target",128))
    limits=compiler_archive_limits(report)
    compiler_ir_validate_report(report,selected,snapshot;limits,historical=true)
    expected_report_sha256===nothing || report["report_sha256"]==expected_report_sha256 ||
        throw(ShenScopeError(:conflict,"Compiler archive filename and report digest disagree"))
    compiler_archive_validate_execution(value["execution"])
    value
end

function compiler_archive_asset(store::CompilerArchiveStore,id::String,ctx::RuntimeContext;entry=nothing,category=:read)
    compiler_archive_hash(id)
    raw=compiler_archive_read_file(store,id*".json",ctx,COMPILER_ARCHIVE_ASSET_BYTES;category)
    if entry!==nothing
        ncodeunits(raw)==entry["asset_bytes"] && digest(raw)==entry["asset_sha256"] ||
            throw(ShenScopeError(:conflict,"Compiler archive asset bytes or digest changed"))
    end
    value=bounded_json_object(raw;maximum=COMPILER_ARCHIVE_ASSET_BYTES,max_depth=96,max_nodes=600_000,error_code=:diagnostics)
    compiler_archive_validate_asset(value,store;expected_report_sha256=id)
    if entry!==nothing
        value["created_at"]==entry["created_at"] && value["report"]["target"]==entry["target"] &&
            value["source"]["fingerprint"]==entry["source_fingerprint"] ||
            throw(ShenScopeError(:conflict,"Compiler archive catalog and evidence metadata disagree"))
    end
    compiler_archive_checkpoint(store,ctx,category)
    (asset=value,bytes=ncodeunits(raw),sha256=digest(raw))
end

function compiler_archive_get(store::CompilerArchiveStore,id::String,ctx::RuntimeContext;
        expected_index_sha256=nothing)
    compiler_archive_hash(id)
    expected_index_sha256===nothing || compiler_archive_hash(expected_index_sha256,"expected catalog digest")
    compiler_archive_authorize(store,ctx,:read)
    index=compiler_archive_read_index(store,ctx)
    expected_index_sha256===nothing || expected_index_sha256==index["index_sha256"] ||
        throw(ShenScopeError(:conflict,"Compiler archive catalog changed"))
    entry=compiler_archive_index_entry(index,id)
    result=compiler_archive_asset(store,id,ctx;entry)
    Dict("entry"=>deepcopy(entry),"report"=>result.asset["report"],"execution"=>result.asset["execution"],
        "recorded_source"=>result.asset["source"],"revision"=>index["revision"],"index_sha256"=>index["index_sha256"],
        "integrity_checked"=>true,"source_currentness"=>"not_checked","producer_authenticated"=>false,
        "validation_scope"=>"recorded inventory, unsigned digests, strict schema and recomputed graph projections")
end
