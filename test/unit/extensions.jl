module ExtensionContractFixtures
using ShenScope
struct MissingTool <: AbstractTool end
struct GoodTool <: AbstractTool end
ShenScope.tool_name(::GoodTool)="fixture"
ShenScope.tool_schema(::GoodTool)=Dict{String,Any}("type"=>"object")
ShenScope.execute(::GoodTool,args::AbstractDict,ctx::RuntimeContext)=nothing
crossed(x::Int,y)=x
crossed(x,y::Int)=y
function late_entry end
function invoke_new_method(ctx)
    @eval late_entry(::Val{:new_entry})=:late_result
    direct=try;late_entry(Val(:new_entry));catch error;error;end
    direct,invoke_extension_latest(late_entry,Val(:new_entry);ctx)
end
end

@testset "Agent tool calling preserves contract evidence without loading code" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"))
        provider=MockProvider([response(;calls=[ToolCall("diagnostics",Dict("action"=>"contracts"))]),response("Contracts inspected.")])
        session=new_session(ctx)
        @test run_agent!(provider,"Inspect loaded Core contracts",ctx;session)=="Contracts inspected."
        tool_message=only(message for message in session.messages if message.role==:tool)
        result=parsejson(tool_message.text)
        @test result["ok"]
        @test all(report->report["valid"],result["value"])
        @test session.status==:complete
    end
end

@testset "Julia interface contracts, ambiguity evidence and world-age boundary" begin
    @test all(report->report["valid"],interface_catalog())
    missing=contract_report(ExtensionContractFixtures.MissingTool)
    @test !missing["valid"]
    @test count(op->op["required"] && !op["valid"],missing["operations"])==3
    good=contract_report(ExtensionContractFixtures.GoodTool())
    @test good["valid"]
    @test any(op->op["operation"]=="mode" && op["status"]=="default",good["operations"])
    @test_throws ShenScopeError contract_report(AbstractTool)
    @test_throws ShenScopeError contract_report(Int)
    report=dispatch_ambiguities([ExtensionContractFixtures.crossed])
    @test length(report["ambiguities"])==1
    @test report["ambiguities"][1]["first"]["line"]>0
    @test !report["truncated"]
    @test dispatch_ambiguities([ExtensionContractFixtures.crossed];max_pairs=1)["checked_pairs"]==1
    @test isempty(dispatch_ambiguities()["ambiguities"])
    @test_throws ShenScopeError dispatch_ambiguities(;max_pairs=0)
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once)
        direct,latest=ExtensionContractFixtures.invoke_new_method(ctx)
        @test direct isa MethodError
        @test latest==:late_result
        called=Ref(false);fn=()->(called[]=true)
        denied=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:dynamic=>Deny)))
        @test_throws ShenScopeError invoke_extension_latest(fn;ctx=denied)
        @test !called[]
        cancel!(ctx.cancellation)
        @test_throws ShenScopeError invoke_extension_latest(fn;ctx)
        @test !called[]
    end
end

@testset "Compiler diagnostics use listed targets, bounded output and independent processes" begin
    bytes=ShenScope.DiagnosticBuffer(UInt8[],0,7)
    @test write(bytes,"🙂🙂")==8
    @test ShenScope.diagnostic_text(bytes)=="🙂"
    @test bytes.total==8
    lowered=compiler_report("cliptext_string";mode="lowered",max_ir_bytes=1024)
    @test lowered["methods"][1]["statements"]>0
    @test ncodeunits(lowered["ir"])<=1024
    @test isvalid(lowered["ir"])
    typed=compiler_report("cliptext_string";max_ir_bytes=1024)
    @test typed["methods"][1]["return"]["type"]=="String"
    @test typed["methods"][1]["return"]["concrete"]
    @test typed["truncated"]
    @test_throws ShenScopeError compiler_report("Base.eval")
    @test_throws ShenScopeError compiler_report("cliptext_string";mode="eval")
    mktempdir() do root
        approvals=Symbol[];events=AgentEvent[]
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->(push!(approvals,r.category);:once),sink=e->push!(events,e))
        result=run_compiler_diagnostic(ctx,"digest_string";max_ir_bytes=1024)
        @test result["target"]=="digest_string"
        @test result["methods"][1]["return"]["type"]=="String"
        @test result["execution"]["separate_process"]
        @test result["execution"]["os_sandbox"]==false
        @test approvals==[:dynamic,:process]
        @test any(e->e.kind==:compiler_diagnostic,events)
        denied=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:dynamic=>Deny,:process=>Allow)))
        @test_throws ShenScopeError execute(DiagnosticsTool(),Dict("action"=>"compile","target"=>"digest_string"),denied)
        @test length(execute(DiagnosticsTool(),Dict("action"=>"contracts"),ctx))>=18
        @test_throws ShenScopeError execute(DiagnosticsTool(),Dict("action"=>"compile"),ctx)
        @test_throws ShenScopeError run_compiler_diagnostic(ctx,"digest_string";timeout=0)
        timeout_ctx=RuntimeContext(root;approve=r->:once)
        @test_throws ShenScopeError run_compiler_diagnostic(timeout_ctx,"digest_string";timeout=0.1)
        @test ctx.sequence>0
    end
end
