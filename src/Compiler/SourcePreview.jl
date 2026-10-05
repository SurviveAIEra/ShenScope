const COMPILER_SOURCE_PREVIEW_BYTES=64*1024
const COMPILER_SOURCE_LINE_BYTES=1024

function compiler_source_positions(method::AbstractDict)
    rows=method["statements"]
    own=count(row->row["source"]["scope"]=="core" && row["source"]["line"]>0,rows)
    external=count(row->row["source"]["scope"]=="external" && row["source"]["line"]>0,rows)
    Dict("core"=>own,"external"=>external,"unknown"=>length(rows)-own-external,
        "runtime_execution_observed"=>false)
end

function compiler_source_checkpoint(ctx::RuntimeContext,root::String)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    permission_decision(ctx.permissions,PermissionRequest("compiler-source-current",:read,
        "runtime.diagnostics",root,"Read installed Core source excerpt"))==Deny &&
        throw(ShenScopeError(:permission,"Compiler source reads were revoked"))
    nothing
end

function compiler_source_location(report::AbstractDict;method_index=1,statement_id=0)
    methods=report["methods"]
    method_index=compiler_ir_integer(method_index,"source method index",1,length(methods))
    method=methods[method_index]
    statement_id=compiler_ir_integer(statement_id,"source statement id",0,length(method["statements"]))
    source=statement_id==0 ? Dict("file"=>method["identity"]["file"],
        "line"=>method["identity"]["line"],"scope"=>"core") : method["statements"][statement_id]["source"]
    source["scope"]=="core" && source["line"] isa Integer && !(source["line"] isa Bool) && source["line"]>0 ||
        throw(ShenScopeError(:diagnostics,"Selected compiler position has no authored Core source"))
    file=compiler_ir_text(source["file"],"preview source path",512)
    startswith(file,"src/") && endswith(file,".jl") && !occursin('\\',file) &&
        all(part->!(part in ("",".","..")),split(file,'/')) ||
        throw(ShenScopeError(:diagnostics,"Compiler preview source path is unsupported"))
    (file=file,line=Int(source["line"]),method_index=method_index,statement_id=statement_id)
end

function compiler_source_excerpt(report::AbstractDict,snapshot::RuntimeSourceSnapshot,ctx::RuntimeContext;
        method_index=1,statement_id=0,context_lines=4,root=runtime_core_root(),authorized=false)
    location=compiler_source_location(report;method_index,statement_id)
    snapshot.uuid==Base.PkgId(@__MODULE__).uuid && report["source"]["fingerprint"]==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"Compiler preview inventory does not match its report"))
    excerpt=compiler_source_excerpt_at(snapshot,ctx,location.file,location.line;
        report_sha256=report["report_sha256"],context_lines,root,authorized)
    merge(excerpt,Dict("schema"=>"shenscope.compiler-source/1","method_index"=>location.method_index,
        "statement_id"=>location.statement_id,"source_mapping"=>"compiler line coordinates; no column precision or executed-path evidence",
        "source_position_counts"=>compiler_source_positions(report["methods"][location.method_index])))
end

function compiler_source_excerpt_at(snapshot::RuntimeSourceSnapshot,ctx::RuntimeContext,file,line;
        report_sha256,context_lines=4,root=runtime_core_root(),authorized=false)
    context_lines=compiler_ir_integer(context_lines,"preview context lines",0,20)
    focus=compiler_ir_integer(line,"preview source line",1,10_000_000)
    source=findfirst(item->item.path==file,snapshot.files)
    source!==nothing && snapshot.uuid==Base.PkgId(@__MODULE__).uuid ||
        throw(ShenScopeError(:diagnostics,"Preview source is absent from the recorded Core inventory"))
    recorded=snapshot.files[source]
    compiler_archive_hash(report_sha256,"preview report hash")
    root=String(root)
    authorized || authorize!(ctx,:read,"runtime.diagnostics",root;
        reason="Read a bounded excerpt of installed Core source, verifying the report's recorded file hash")
    compiler_source_checkpoint(ctx,root)
    text=read_scoped_text(ctx,root,file,RUNTIME_SOURCE_MAX_FILE_BYTES;authorized=true,
        tool="runtime.diagnostics",reason="Read hash-verified compiler source excerpt")
    ncodeunits(text)==recorded.bytes && digest(text)==recorded.sha256 ||
        throw(ShenScopeError(:conflict,"Current Core source differs from the compiler report's recorded file"))
    first=max(1,focus-context_lines);requested_last=focus+context_lines
    rows=Dict{String,Any}[];total_lines=0
    for (number,line) in enumerate(eachsplit(text,'\n';keepempty=true))
        total_lines=number
        if first<=number<=requested_last
            value=String(chopsuffix(line,"\r"))
            clipped=ncodeunits(value)>COMPILER_SOURCE_LINE_BYTES
            push!(rows,Dict("line"=>number,"text"=>clipped ? cliptext(value,COMPILER_SOURCE_LINE_BYTES) : value,
                "focus"=>number==focus,"truncated"=>clipped))
        end
        if number%4096==0;compiler_source_checkpoint(ctx,root);yield();end
    end
    focus<=total_lines || throw(ShenScopeError(:conflict,"Compiler position is beyond the verified source file"))
    last=min(total_lines,requested_last)
    result=Dict("schema"=>"shenscope.source-excerpt/1","report_sha256"=>report_sha256,
        "source_fingerprint"=>snapshot.fingerprint,"source_sha256"=>recorded.sha256,
        "file"=>file,"focus_line"=>focus,"first_line"=>first,"last_line"=>last,"total_lines"=>total_lines,
        "lines"=>rows,"truncated_lines"=>count(row->row["truncated"],rows),
        "file_currentness"=>"bytes_match_recorded_hash","producer_authenticated"=>false)
    compiler_source_checkpoint(ctx,root)
    bounded_canonical_json(result;maximum=COMPILER_SOURCE_PREVIEW_BYTES)
    result
end

function compiler_archive_source(store::CompilerArchiveStore,id::String,ctx::RuntimeContext;
        expected_index_sha256=nothing,kwargs...)
    archived=compiler_archive_get(store,id,ctx;expected_index_sha256)
    source=runtime_source_from_view(archived["recorded_source"])
    result=compiler_source_excerpt(archived["report"],source,ctx;kwargs...)
    compiler_archive_checkpoint(store,ctx,:read)
    merge(result,Dict("recorded_report"=>true,"index_sha256"=>archived["index_sha256"],
        "revision"=>archived["revision"],"inventory_currentness"=>"not_checked"))
end
