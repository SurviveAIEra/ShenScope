function compiler_archive_context(root;session_id="archive-owner",kwargs...)
    RuntimeContext(root;session_id,state_dir=joinpath(root,"state"),
        permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow,:persistence=>Allow)),kwargs...)
end

function compiler_archive_recorded_fixture()
    source=parsejson(read(joinpath(@__DIR__,"compiler_archive_source_031.json"),String))
    delete!(source,"source_commit")
    result=parsejson(read(joinpath(@__DIR__,"../../docs/validation/compiler-ir-031/compiler-ir-cli-result.json"),String))
    (result=result,source=source)
end

# Install explicit unsigned fixture evidence. This does not attest that a
# producer executed a child; production RPC only saves a completed owned job.
function compiler_archive_install_fixture!(store,ctx,result,source;title="Recorded fixture")
    id=result["report"]["report_sha256"]
    asset=Dict("schema"=>ShenScope.COMPILER_ARCHIVE_SCHEMA,"owner"=>ShenScope.compiler_archive_owner(store),
        "created_at"=>"2026-10-05T00:00:00Z","source"=>deepcopy(source),
        "report"=>deepcopy(result["report"]),"execution"=>deepcopy(result["execution"]))
    ShenScope.compiler_archive_validate_asset(asset,store;expected_report_sha256=id)
    raw=canonical(asset);mkpath(store.directory);atomic_write(joinpath(store.directory,id*".json"),raw)
    index=ShenScope.compiler_archive_read_index(store,ctx)
    rows=vcat(index["reports"],[Dict("report_sha256"=>id,"asset_sha256"=>digest(raw),"asset_bytes"=>ncodeunits(raw),
        "target"=>result["report"]["target"],"source_fingerprint"=>source["fingerprint"],
        "created_at"=>asset["created_at"],"title"=>title)])
    ShenScope.compiler_archive_publish_index(store,ctx,index,rows)
    id
end
