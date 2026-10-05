function compiler_archive_validate_entry(value,store::CompilerArchiveStore)
    compiler_ir_fields(value,["report_sha256","asset_sha256","asset_bytes","target","source_fingerprint",
        "created_at","title"],"archive catalog entry")
    compiler_archive_hash(value["report_sha256"])
    compiler_archive_hash(value["asset_sha256"],"asset digest")
    compiler_archive_hash(value["source_fingerprint"],"source fingerprint")
    compiler_ir_integer(value["asset_bytes"],"asset bytes",1,COMPILER_ARCHIVE_ASSET_BYTES)
    compiler_target(compiler_ir_text(value["target"],"archive target",128))
    compiler_archive_timestamp(value["created_at"])
    compiler_ir_text(value["title"],"archive title",512)
    nothing
end

function compiler_archive_validate_index(value,store::CompilerArchiveStore)
    compiler_ir_fields(value,["schema","owner","revision","reports","index_sha256"],"archive index")
    value["schema"]==COMPILER_ARCHIVE_SCHEMA && value["owner"]==compiler_archive_owner(store) ||
        throw(ShenScopeError(:permission,"Compiler archive index has a foreign owner or schema"))
    compiler_archive_revision(value["revision"])
    rows=value["reports"]
    rows isa AbstractVector && length(rows)<=store.limits.max_reports ||
        throw(ShenScopeError(:capacity,"Compiler archive catalog exceeds its report limit"))
    for row in rows;compiler_archive_validate_entry(row,store);end
    ids=[row["report_sha256"] for row in rows]
    issorted(ids) && length(unique(ids))==length(ids) || throw(ShenScopeError(:diagnostics,"Compiler archive catalog is not sorted and unique"))
    checksum=compiler_archive_hash(value["index_sha256"],"catalog digest")
    original=Dict(key=>item for (key,item) in value if key!="index_sha256")
    digest(canonical(original))==checksum || throw(ShenScopeError(:conflict,"Compiler archive catalog digest changed"))
    sum(row["asset_bytes"] for row in rows;init=0)<=store.limits.max_total_bytes ||
        throw(ShenScopeError(:capacity,"Referenced compiler archive evidence exceeds its byte limit"))
    value
end

function compiler_archive_read_index(store::CompilerArchiveStore,ctx::RuntimeContext;category=:read)
    path=compiler_archive_path(store,"index.json",ctx)
    if !ispath(path)
        compiler_archive_checkpoint(store,ctx,category)
        return compiler_archive_empty_index(store)
    end
    raw=compiler_archive_read_file(store,"index.json",ctx,COMPILER_ARCHIVE_INDEX_BYTES;category)
    value=bounded_json_object(raw;maximum=COMPILER_ARCHIVE_INDEX_BYTES,max_depth=8,max_nodes=40_000,error_code=:diagnostics)
    compiler_archive_validate_index(value,store)
end

function compiler_archive_index_entry(index,id::String)
    compiler_archive_hash(id)
    position=findfirst(row->row["report_sha256"]==id,index["reports"])
    position===nothing && throw(ShenScopeError(:diagnostics,"Compiler report is not in this conversation's archive"))
    index["reports"][position]
end

function compiler_archive_publish_index(store::CompilerArchiveStore,ctx::RuntimeContext,previous,rows;
        guard=()->nothing,notification_failed=Ref(false))
    revision=compiler_archive_revision(previous["revision"])+1
    index=Dict{String,Any}("schema"=>COMPILER_ARCHIVE_SCHEMA,"owner"=>compiler_archive_owner(store),
        "revision"=>revision,"reports"=>sort!(collect(rows);by=row->row["report_sha256"]))
    index["index_sha256"]=digest(canonical(index));compiler_archive_validate_index(index,store)
    raw=bounded_canonical_json(index;maximum=COMPILER_ARCHIVE_INDEX_BYTES,max_depth=8,max_nodes=40_000)
    compiler_archive_write_file(store,"index.json",raw,ctx;maximum=COMPILER_ARCHIVE_INDEX_BYTES,guard=()->begin
        guard()
        current=compiler_archive_read_index(store,ctx;category=:persistence)
        current["index_sha256"]==previous["index_sha256"] || throw(ShenScopeError(:conflict,"Compiler archive changed before catalog publication"))
    end)
    try
        emit!(ctx,:compiler_archive_committed,Dict("revision"=>revision,"index_sha256"=>index["index_sha256"],"reports"=>length(rows)))
    catch
        # The catalog is already durable. A disconnected notification sink
        # cannot turn its successful atomic publication into a storage failure.
        notification_failed[]=true
    end
    index
end

function compiler_archive_transaction(f::Function,store::CompilerArchiveStore,ctx::RuntimeContext,expected_revision)
    revision=compiler_archive_revision(expected_revision)
    compiler_archive_authorize(store,ctx,:persistence)
    compiler_archive_path(store,"index.json.lock",ctx)
    store_lock(compiler_archive_index_path(store);checkpoint=()->begin
        compiler_archive_checkpoint(store,ctx,:persistence);compiler_archive_path(store,"index.json.lock",ctx)
    end) do
        previous=compiler_archive_read_index(store,ctx;category=:persistence)
        previous["revision"]==revision || throw(ShenScopeError(:conflict,"Compiler archive revision changed; refresh the catalog"))
        f(previous)
    end
end

function compiler_archive_list(store::CompilerArchiveStore,ctx::RuntimeContext;
        offset=0,limit=20,target=nothing,expected_index_sha256=nothing)
    offset=compiler_ir_integer(offset,"archive offset",0,10_000)
    limit=compiler_ir_integer(limit,"archive page limit",1,100)
    target===nothing || compiler_target(target)
    expected_index_sha256===nothing || compiler_archive_hash(expected_index_sha256,"expected catalog digest")
    compiler_archive_authorize(store,ctx,:read)
    index=compiler_archive_read_index(store,ctx)
    expected_index_sha256===nothing || expected_index_sha256==index["index_sha256"] ||
        throw(ShenScopeError(:conflict,"Compiler archive page changed; restart pagination"))
    rows=filter(row->target===nothing || row["target"]==target,index["reports"])
    ordered=sort!(collect(rows);by=row->(row["created_at"],row["report_sha256"]),rev=true)
    last=min(length(ordered),offset+limit)
    page=offset<length(ordered) ? deepcopy(ordered[offset+1:last]) : Any[]
    disk=compiler_archive_disk_inventory(store,ctx)
    compiler_archive_checkpoint(store,ctx,:read)
    referenced=Set(row["report_sha256"] for row in index["reports"])
    Dict("revision"=>index["revision"],"index_sha256"=>index["index_sha256"],"items"=>page,"total"=>length(rows),
        "next_offset"=>last<length(ordered) ? last : nothing,"asset_bytes"=>disk["asset_bytes"],"staging_bytes"=>disk["staging_bytes"],
        "orphan_assets"=>count(id->!(id in referenced),keys(disk["assets"])),
        "limits"=>Dict("reports"=>store.limits.max_reports,"asset_bytes"=>store.limits.max_total_bytes),
        "order"=>"recorded time descending, report digest descending","owner"=>compiler_archive_owner(store))
end
