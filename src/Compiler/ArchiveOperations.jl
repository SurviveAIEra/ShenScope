function compiler_archive_save(store::CompilerArchiveStore,result::AbstractDict,ctx::RuntimeContext;
        expected_revision,title="Compiler report")
    title=compiler_ir_text(title,"archive title",512)
    compiler_ir_fields(result,["report","execution"],"compiler result to archive")
    compiler_archive_validate_execution(result["execution"])
    report=result["report"]
    report isa AbstractDict || throw(ShenScopeError(:diagnostics,"Compiler result has no structured report"))
    selected=compiler_target(compiler_ir_text(get(report,"target",nothing),"compiler archive target",128))
    compiler_archive_revision(expected_revision)
    compiler_archive_checkpoint(store,ctx,:persistence)
    snapshot=runtime_source_snapshot(ctx)
    compiler_ir_validate_report(report,selected,snapshot;limits=compiler_archive_limits(report))
    id=compiler_archive_hash(report["report_sha256"])
    compiler_archive_transaction(store,ctx,expected_revision) do index
        prior=findfirst(row->row["report_sha256"]==id,index["reports"])
        if prior!==nothing
            stored=compiler_archive_asset(store,id,ctx;entry=index["reports"][prior],category=:persistence)
            stored.asset["report"]==report && stored.asset["execution"]==result["execution"] ||
                throw(ShenScopeError(:conflict,"Compiler archive digest identifies different evidence or execution metadata"))
            return Dict("saved"=>true,"already_saved"=>true,"revision"=>index["revision"],
                "index_sha256"=>index["index_sha256"],"entry"=>deepcopy(index["reports"][prior]))
        end
        length(index["reports"])<store.limits.max_reports || throw(ShenScopeError(:capacity,"Compiler archive report limit reached"))
        disk=compiler_archive_disk_inventory(store,ctx;category=:persistence)
        haskey(disk["assets"],id) || length(disk["assets"])<store.limits.max_reports+32 ||
            throw(ShenScopeError(:capacity,"Compiler archive orphan inventory is full; review owned cleanup"))
        asset=Dict("schema"=>COMPILER_ARCHIVE_SCHEMA,"owner"=>compiler_archive_owner(store),
            "created_at"=>string(now(UTC))*"Z","source"=>runtime_source_view(snapshot),
            "report"=>deepcopy(report),"execution"=>deepcopy(result["execution"]))
        compiler_archive_validate_asset(asset,store;expected_report_sha256=id)
        if haskey(disk["assets"],id)
            stored=compiler_archive_asset(store,id,ctx;category=:persistence)
            stored.asset["report"]==report && stored.asset["source"]==asset["source"] &&
                stored.asset["execution"]==asset["execution"] ||
                throw(ShenScopeError(:conflict,"Orphan compiler archive evidence does not match the requested report"))
            asset=stored.asset
        end
        raw=bounded_canonical_json(asset;maximum=COMPILER_ARCHIVE_ASSET_BYTES,max_depth=64,max_nodes=600_000)
        bytes=ncodeunits(raw)
        disk["asset_bytes"]+disk["staging_bytes"]+(haskey(disk["assets"],id) ? 0 : bytes)<=store.limits.max_total_bytes ||
            throw(ShenScopeError(:capacity,"Compiler archive storage limit reached; review orphan cleanup or delete an owned report"))
        runtime_source_snapshot(ctx;authorized=true).fingerprint==snapshot.fingerprint ||
            throw(ShenScopeError(:conflict,"Core source changed before compiler archive publication"))
        if !haskey(disk["assets"],id)
            compiler_archive_write_file(store,id*".json",raw,ctx;maximum=COMPILER_ARCHIVE_ASSET_BYTES,
                guard=()->ispath(compiler_archive_path(store,id*".json",ctx)) &&
                    throw(ShenScopeError(:conflict,"Compiler archive asset appeared before publication")))
        end
        emit!(ctx,:compiler_archive_asset_saved,Dict("report_sha256"=>id,"asset_bytes"=>bytes))
        entry=Dict("report_sha256"=>id,"asset_sha256"=>digest(raw),"asset_bytes"=>bytes,"target"=>report["target"],
            "source_fingerprint"=>snapshot.fingerprint,"created_at"=>asset["created_at"],"title"=>title)
        committed=compiler_archive_publish_index(store,ctx,index,vcat(index["reports"],[entry]);guard=()->begin
            runtime_source_snapshot(ctx;authorized=true).fingerprint==snapshot.fingerprint ||
                throw(ShenScopeError(:conflict,"Core source changed before compiler archive catalog publication"))
        end)
        Dict("saved"=>true,"already_saved"=>false,"revision"=>committed["revision"],
            "index_sha256"=>committed["index_sha256"],"entry"=>entry)
    end
end

function compiler_archive_label(store::CompilerArchiveStore,id::String,title::String,ctx::RuntimeContext;expected_revision)
    compiler_archive_hash(id);compiler_ir_text(title,"archive title",512)
    compiler_archive_transaction(store,ctx,expected_revision) do index
        entry=compiler_archive_index_entry(index,id);rows=deepcopy(index["reports"])
        position=findfirst(row->row["report_sha256"]==id,rows)
        if entry["title"]==title
            return Dict("changed"=>false,"revision"=>index["revision"],"index_sha256"=>index["index_sha256"],"entry"=>deepcopy(entry))
        end
        rows[position]["title"]=title
        committed=compiler_archive_publish_index(store,ctx,index,rows)
        Dict("changed"=>true,"revision"=>committed["revision"],"index_sha256"=>committed["index_sha256"],"entry"=>rows[position])
    end
end

function compiler_archive_delete(store::CompilerArchiveStore,id::String,ctx::RuntimeContext;expected_revision)
    compiler_archive_hash(id)
    compiler_archive_transaction(store,ctx,expected_revision) do index
        compiler_archive_index_entry(index,id)
        rows=filter(row->row["report_sha256"]!=id,index["reports"])
        committed=compiler_archive_publish_index(store,ctx,index,rows)
        Dict("deleted"=>true,"report_sha256"=>id,"revision"=>committed["revision"],
            "index_sha256"=>committed["index_sha256"],"asset_removal"=>"retained until explicit orphan cleanup")
    end
end

function compiler_archive_cleanup_plan(store::CompilerArchiveStore,ctx::RuntimeContext,index;category=:read)
    disk=compiler_archive_disk_inventory(store,ctx;category)
    referenced=Set(row["report_sha256"] for row in index["reports"])
    ids=sort!([id for id in keys(disk["assets"]) if !(id in referenced)])
    candidates=Dict{String,Any}[]
    for id in ids
        verified=compiler_archive_asset(store,id,ctx;category)
        push!(candidates,Dict("report_sha256"=>id,"asset_sha256"=>verified.sha256,"bytes"=>verified.bytes))
    end
    Dict("revision"=>index["revision"],"index_sha256"=>index["index_sha256"],"items"=>candidates,
        "reclaimable_bytes"=>sum(row["bytes"] for row in candidates;init=0),"referenced_reports"=>length(referenced),
        "deletes_referenced_reports"=>false)
end

function compiler_archive_gc(store::CompilerArchiveStore,ctx::RuntimeContext;dry_run=true,expected_revision=nothing)
    dry_run isa Bool || throw(ShenScopeError(:diagnostics,"Compiler archive cleanup dry_run must be Boolean"))
    if dry_run
        compiler_archive_authorize(store,ctx,:read)
        index=compiler_archive_read_index(store,ctx)
        expected_revision===nothing || index["revision"]==compiler_archive_revision(expected_revision) ||
            throw(ShenScopeError(:conflict,"Compiler archive changed before cleanup planning"))
        return merge(compiler_archive_cleanup_plan(store,ctx,index),Dict("dry_run"=>true,"removed_assets"=>0))
    end
    expected_revision===nothing && throw(ShenScopeError(:diagnostics,"Compiler archive cleanup requires the expected revision"))
    compiler_archive_transaction(store,ctx,expected_revision) do index
        plan=compiler_archive_cleanup_plan(store,ctx,index;category=:persistence)
        removed=0;reclaimed=0
        for entry in plan["items"]
            compiler_archive_checkpoint(store,ctx,:persistence)
            current=compiler_archive_read_index(store,ctx;category=:persistence)
            current["index_sha256"]==index["index_sha256"] || throw(ShenScopeError(:conflict,"Compiler archive changed during cleanup"))
            id=entry["report_sha256"];verified=compiler_archive_asset(store,id,ctx;category=:persistence)
            verified.sha256==entry["asset_sha256"] || throw(ShenScopeError(:conflict,"Compiler archive cleanup candidate changed"))
            rm(compiler_archive_path(store,id*".json",ctx));removed+=1;reclaimed+=verified.bytes
        end
        sync_directory(store.directory)
        merge(plan,Dict("dry_run"=>false,"removed_assets"=>removed,"reclaimed_bytes"=>reclaimed,
            "partial_cleanup_possible_on_interruption"=>true))
    end
end
