@testset "CLI navigation encodes one owned cursor or symbol with bounded evidence paging" begin
    arguments(values)=begin
        positional,flags=ShenScope.parse_cli(values)
        args=ShenScope.cli_project_arguments(positional,flags)
        ShenScope.validate_tool_arguments(ProjectTool(),args);args
    end
    cursor=arguments(["project","definitions","中文.ts","2","9","--backend","typescript","--column-unit","utf16","--revision","3"])
    @test cursor["file"]=="中文.ts" && cursor["column"]==9 && cursor["revision"]==3
    @test cursor["column_unit"]=="utf16"
    id=repeat("a",32)
    by_id=arguments(["project","references","--symbol",id,"--limit","1","--offset","2","--exclude-declarations"])
    @test by_id["symbol_id"]==id && by_id["offset"]==2 && !by_id["include_declarations"]
    @test arguments(["project","diagnostics","a.ts"])["file"]=="a.ts"
    @test !haskey(arguments(["project","diagnostics"]),"file")
    compact=arguments(["project","compact","--backend","typescript","--force","--minimum-savings","1024","--revision","3"])
    @test compact["force"] && compact["minimum_savings"]==1024 && compact["revision"]==3
    for values in (["project","definitions","a.ts","x","1"], ["project","references","--symbol",id,"a.ts"],
            ["project","diagnostics","a.ts","extra"], ["project","hover","a.ts","0","1"],
            ["project","definitions","a.ts","1","1","--column-unit","utf32"],
            ["project","incoming_calls","--symbol",id,"--limit","0"])
        @test_throws ShenScopeError arguments(values)
    end
end

@testset "CLI history filters preserve indexed seed identity and integer limits" begin
    values=["project","git_cochange","中文.jl","--history-limit","7","--bulk-threshold","2","--minimum-support","3","--limit","4","--revision","2"]
    positional,flags=ShenScope.parse_cli(values)
    arguments=ShenScope.cli_project_arguments(positional,flags)
    ShenScope.validate_tool_arguments(ProjectTool(),arguments)
    @test arguments["paths"]==["中文.jl"] && arguments["history_limit"]==7 && arguments["minimum_support"]==3
    @test arguments["bulk_threshold"]==2 && arguments["limit"]==4 && arguments["revision"]==2
    for option in ("--history-limit","--bulk-threshold","--minimum-support")
        @test_throws ShenScopeError begin
            p,f=ShenScope.parse_cli(["project","risk",option,"x"]);ShenScope.cli_project_arguments(p,f)
        end
    end
end
