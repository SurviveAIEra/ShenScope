@testset "Runtime declaration interval joins agree with an independent containment oracle" begin
    ctx=RuntimeContext(pwd();permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    snapshot=runtime_source_snapshot(ctx);source=first(snapshot.files);sha=source.sha256
    declarations=ShenScope.RuntimeEvidenceDeclaration[]
    for (ordinal,(first,last)) in enumerate([(1,80),(3,10),(5,5),(10,30),(10,30),(35,60),(70,90)])
        symbol=CodeSymbol(ShenScope.symbol_id("interval",ordinal),:method,"f$ordinal","f$ordinal",
            SourceRange(source.path,first,last),:julia,Dict{String,Any}())
        push!(declarations,ShenScope.RuntimeEvidenceDeclaration(digest("interval:$ordinal"),"oracle",symbol,sha))
    end
    indexes=ShenScope.runtime_evidence_intervals(declarations)
    work=ShenScope.RuntimeEvidenceWork(ShenScope.RuntimeEvidenceLimits(),0,ctx)
    for line in (1,2,3,5,6,10,11,30,31,35,60,61,70,80,81,90,91,100)
        row=Dict("kind"=>"statement","key"=>digest("row:$line"),
            "source"=>Dict("file"=>source.path,"line"=>line,"source_sha256"=>sha))
        candidates=ShenScope.runtime_evidence_candidates(row,indexes,work)
        oracle=sort!([item.key for item in declarations if item.symbol.location.start_line<=line<=item.symbol.location.end_line])
        @test getfield.(candidates,:key)==oracle
        joined=ShenScope.runtime_evidence_join_row(row,candidates)
        @test joined["candidate_count"]==length(oracle) && !joined["semantic_equivalence_confirmed"]
        @test all(witness->!witness["runtime_binding_confirmed"] && witness["source_sha256"]==sha,joined["declaration_candidates"])
    end
    narrow=ShenScope.RuntimeEvidenceWork(ShenScope.RuntimeEvidenceLimits(;candidates=1),0,ctx)
    row=Dict("source"=>Dict("file"=>source.path,"line"=>5,"source_sha256"=>sha))
    @test_throws ShenScopeError ShenScope.runtime_evidence_candidates(row,indexes,narrow)
    row["source"]["source_sha256"]=repeat("0",64)
    @test_throws ShenScopeError ShenScope.runtime_evidence_candidates(row,indexes,work)
    for options in ((;files=true),(;declarations=9000),(;observations=40_001),(;candidates=0),(;read_bytes=512),(;join_operations=0))
        @test_throws ShenScopeError ShenScope.RuntimeEvidenceLimits(;options...)
    end
end

@testset "Actual inferred source joins are bounded, paged and hash verified" begin
    root=ShenScope.runtime_core_root();ctx=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow)))
    compiler=ShenScope.compiler_ir_report("cliptext_string");snapshot=runtime_source_snapshot(ctx)
    evidence=ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx)
    page=ShenScope.runtime_evidence_page(evidence,ctx;limit=4)
    @test page["summary"]["observations"]==1+length(only(compiler["methods"])["statements"])
    @test page["summary"]["join_statuses"]["unique_declaration_start"]==1
    @test page["summary"]["join_statuses"]["unique_containing_declaration"]>40
    @test page["summary"]["join_statuses"]["no_source_position"]>0
    @test page["next_offset"]==4 && length(page["items"])==4
    next=ShenScope.runtime_evidence_page(evidence,ctx;offset=4,limit=4,expected_evidence_sha256=page["evidence_sha256"])
    @test next["evidence_sha256"]==page["evidence_sha256"] && isempty(intersect(getindex.(page["items"],"key"),getindex.(next["items"],"key")))
    methods=ShenScope.runtime_evidence_page(evidence,ctx;observation_kind="method")
    @test methods["total"]==1 && only(methods["items"])["join_status"]=="unique_declaration_start"
    @test only(page["provider_stamps"])["persistent_index_revision"]===nothing
    @test !only(page["provider_stamps"])["source_evaluated"] && !page["summary"]["allocation_observation_bytes_are_additive"]
    @test !occursin(root,canonical(page))
    row=only(methods["items"])
    preview=ShenScope.runtime_evidence_source(evidence,row["key"],ctx;expected_evidence_sha256=page["evidence_sha256"])
    @test preview["file"]==row["source"]["file"] && preview["focus_line"]==row["source"]["line"]
    @test preview["source_sha256"]==digest(read(joinpath(root,preview["file"]),String))
    @test count(item->item["focus"],preview["lines"])==1 && preview["observation_kind"]=="method"
    @test_throws ShenScopeError ShenScope.runtime_evidence_source(evidence,row["key"],ctx;expected_evidence_sha256=nothing)
    @test_throws ShenScopeError ShenScope.runtime_evidence_source(evidence,digest("unknown"),ctx;expected_evidence_sha256=evidence.fingerprint)
    unknown=first(item for item in evidence.rows if item["source"]["file"]===nothing)
    @test_throws ShenScopeError ShenScope.runtime_evidence_source(evidence,unknown["key"],ctx;expected_evidence_sha256=evidence.fingerprint)
    for options in ((;offset=true),(;limit=129),(;query="\0"),(;observation_kind="coverage"),(;expected_evidence_sha256=repeat("0",64)),(;offset=40_000))
        @test_throws ShenScopeError ShenScope.runtime_evidence_page(evidence,ctx;options...)
    end
    empty=ShenScope.runtime_evidence_page(evidence,ctx;query="a declaration that cannot be present")
    @test empty["total"]==0 && empty["next_offset"]===nothing
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(nothing,nothing,snapshot,ctx)
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx;limits=ShenScope.RuntimeEvidenceLimits(;declarations=1))
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx;limits=ShenScope.RuntimeEvidenceLimits(;observations=1))
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx;limits=ShenScope.RuntimeEvidenceLimits(;join_operations=1))
    drift=deepcopy(compiler);drift["source"]["fingerprint"]=repeat("0",64)
    drift["report_sha256"]=digest(canonical(Dict(key=>value for (key,value) in drift if key!="report_sha256")))
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(drift,nothing,snapshot,ctx)
    invalid_rows=[Dict("source"=>Dict("file"=>row["source"]["file"],"line"=>10_000_000))]
    @test_throws ShenScopeError ShenScope.runtime_evidence_read_facts(invalid_rows,snapshot,ctx,ShenScope.RuntimeEvidenceLimits())
    deny=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Deny,:process=>Deny)))
    for options in (Dict("limit"=>129),Dict("offset"=>true),Dict("observation_kind"=>"coverage"))
        error=try
            execute(DiagnosticsTool(),merge(Dict("action"=>"inspect","target"=>"digest_string"),options),deny)
            nothing
        catch caught
            caught
        end
        @test error isa ShenScopeError && error.code==:diagnostics
    end
    ctx.permissions.rules[:read]=Deny
    @test_throws ShenScopeError ShenScope.runtime_evidence_page(evidence,ctx)
    @test_throws ShenScopeError ShenScope.runtime_evidence_build(compiler,nothing,snapshot,ctx)
end
