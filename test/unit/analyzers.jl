@testset "Analyzer definitions and session registry" begin
    source = "selftest()=true\nanalyze(d,r)=Dict(\"total\"=>sum(d[\"values\"]))"
    test = AnalyzerTestCase("sum",Dict("values"=>[1,2]),Dict(),Dict("total"=>3))
    definition = AnalyzerDefinition("sample.sum",source;description="Sum values",tests=[test])
    @test definition.source_sha256 == digest(source)
    @test ShenScope.analyzer_definition_from_dict(ShenScope.analyzer_definition_dict(definition)).version == definition.version
    for name in ("", "impact", "UPPER", "../escape",repeat("a",65))
        @test_throws ShenScopeError AnalyzerDefinition(name,source)
    end
    @test_throws ShenScopeError AnalyzerTestCase("",Dict{String,Any}(),Dict{String,Any}(),Dict{String,Any}())
    @test_throws ShenScopeError AnalyzerDefinition("sample",source;tests=[test,test])
    @test_throws ShenScopeError AnalyzerDefinition("sample",source;description=repeat("a",2049))
    bad = deepcopy(ShenScope.analyzer_definition_dict(definition));bad["source"] *= "\n#changed"
    @test_throws ShenScopeError ShenScope.analyzer_definition_from_dict(bad)
    observed = ShenScope.analyzer_compare_external_tests(definition,[Dict("total"=>3)])
    @test observed["passed"] && observed["count"] == 1
    @test !ShenScope.analyzer_compare_external_tests(definition,[Dict("total"=>4)])["passed"]
    @test_throws ShenScopeError ShenScope.analyzer_compare_external_tests(definition,Any[])
    @test !ShenScope.analyzer_compare_external_tests(AnalyzerDefinition("no.tests",source),Any[])["passed"]
    mktempdir() do root
        policy = PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Allow,:process=>Allow))
        ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),session_id="owner",permissions=policy)
        stranger = RuntimeContext(root;state_dir=ctx.state_dir,session_id="stranger",permissions=policy)
        manager = AnalyzerManager(;max_records=2)
        first = register_analyzer!(manager,definition,ctx)
        @test first["selected"] && first["lifetime"] == "session"
        @test register_analyzer!(manager,definition,ctx) == first
        @test analyzer_list(manager,ctx)["total"] == 1
        @test analyzer_list(manager,stranger)["total"] == 0
        @test_throws ShenScopeError analyzer_inspect(manager,definition.name,stranger;version=definition.version)
        inspected = analyzer_inspect(manager,definition.name,ctx)
        inspected["tests"][1]["data"]["values"][1] = 99
        @test analyzer_inspect(manager,definition.name,ctx)["tests"][1]["data"]["values"][1] == 1
        second = AnalyzerDefinition(definition.name,source*"\n# version two";tests=[test])
        @test !register_analyzer!(manager,second,ctx)["selected"]
        @test analyzer_inspect(manager,definition.name,ctx)["definition"]["version"] == definition.version
        @test select_analyzer!(manager,definition.name,second.version,ctx)["selected"]
        @test analyzer_inspect(manager,definition.name,ctx)["definition"]["version"] == second.version
        @test_throws ShenScopeError register_analyzer!(manager,AnalyzerDefinition("third",source),ctx)
        lease = ShenScope.analyzer_begin_run!(manager,definition.name,ctx)
        @test_throws ShenScopeError remove_analyzer!(manager,definition.name,ctx)
        @test cancel_analyzer!(manager,definition.name,ctx)["cancelled"] == 1
        @test iscancelled(lease.context.cancellation) && !iscancelled(ctx.cancellation)
        ShenScope.analyzer_finish_run!(manager,lease;failure="cancelled")
        @test remove_analyzer!(manager,definition.name,ctx)["removed"]
        @test analyzer_list(manager,ctx)["total"] == 1
        cleanup_analyzers!(manager;session_id=stranger.session_id)
        @test analyzer_list(manager,ctx)["total"] == 1
        cleanup_analyzers!(manager;session_id=ctx.session_id)
        @test isempty(manager.records) && isempty(manager.selected)
        tool = AnalyzersTool()
        @test execute(tool,Dict("action"=>"status"),ctx)["fallback"] == false
        @test_throws ShenScopeError execute(tool,Dict("action"=>"register","name"=>"sample"),ctx)
        @test_throws ShenScopeError execute(tool,Dict("action"=>"register","name"=>"sample","source"=>source,"source_path"=>"x"),ctx)
        @test_throws ShenScopeError validate_schema(Dict("action"=>"register","name"=>"x","unexpected"=>true),tool_schema(tool))
        source_path = joinpath(root,"sample.jl");write(source_path,source)
        registered = execute(tool,Dict("action"=>"register","name"=>"sample","source_path"=>source_path),ctx)
        @test registered["definition"]["source_sha256"] == digest(source)
        symlink(source_path,joinpath(root,"alias.jl"))
        @test_throws ShenScopeError execute(tool,Dict("action"=>"register","name"=>"alias","source_path"=>"alias.jl"),ctx)
    end
end
