@testset "Workspace tools conflict guard, schema and transactional validation" begin
    mktempdir() do root
        ctx=model_context(root)
        write(joinpath(root,"sample.py"),"def add(a, b):\n    return a - b\n")
        readresult=execute(ReadTool(),Dict("path"=>"sample.py"),ctx)
        @test readresult["sha256"]==digest(read(joinpath(root,"sample.py"),String))
        result=execute(SearchTool(),Dict("query"=>"return"),ctx)
        @test result["matches"][1]["line"]==2
        edit=Dict("path"=>"sample.py","old"=>"a - b","new"=>"a + b","expected_sha256"=>readresult["sha256"])
        execute(EditTool(),edit,ctx)
        @test occursin("a + b",read(joinpath(root,"sample.py"),String))
        @test_throws ShenScopeError execute(EditTool(),edit,ctx)
        @test_throws ShenScopeError validate_schema(Dict("path"=>3),tool_schema(ReadTool()))
        @test_throws ShenScopeError validate_schema(Dict("path"=>"x","surprise"=>true),tool_schema(ReadTool()))
        good=Dict("path"=>"sample.py","old"=>"a + b","new"=>"a * b","expected_sha256"=>digest(read(joinpath(root,"sample.py"),String)))
        bad=Dict("path"=>"missing.py","old"=>"x","new"=>"y","expected_sha256"=>"bad")
        @test_throws ShenScopeError execute(PatchTool(),Dict("edits"=>[good,bad]),ctx)
        @test occursin("a + b",read(joinpath(root,"sample.py"),String))
        @test !any(endswith(".lock"),readdir(root))
    end
end

@testset "Process execution, bounded logs, ownership, input and timeout" begin
    mktempdir() do root
        ctx=model_context(root);t=ProcessTool()
        python=Sys.which("python")
        output=execute(t,Dict("action"=>"run","argv"=>[python,"-c","import sys; print('hello'); print('error',file=sys.stderr); sys.exit(7)"]),ctx)
        @test output["exit_code"]==7
        @test occursin("hello",output["stdout"])
        @test occursin("error",output["stderr"])
        h=execute(t,Dict("action"=>"start","argv"=>[python,"-u","-c","print(input())"]),ctx)
        child=RuntimeContext(root;state_dir=ctx.state_dir)
        @test_throws ShenScopeError execute(t,Dict("action"=>"poll","handle"=>h["handle"]),child)
        execute(t,Dict("action"=>"write","handle"=>h["handle"],"input"=>"中文\n","close_input"=>true),ctx)
        deadline=time()+5
        result=execute(t,Dict("action"=>"poll","handle"=>h["handle"]),ctx)
        while result["running"] && time()<deadline
            sleep(0.025)
            result=execute(t,Dict("action"=>"poll","handle"=>h["handle"]),ctx)
        end
        @test !result["running"]
        @test occursin("中文",result["stdout"])
        @test execute(t,Dict("action"=>"poll","handle"=>h["handle"]),ctx)["stdout"]==result["stdout"]
        slow=execute(t,Dict("action"=>"run","argv"=>[python,"-c","import time; time.sleep(5)"],"timeout"=>0.1),ctx)
        @test slow["timed_out"]
        @test slow["elapsed_seconds"]<3
        large=execute(t,Dict("action"=>"run","argv"=>[python,"-c","print('A'*400000); print('FINAL')"]),ctx)
        @test ncodeunits(large["stdout"])<270000
        @test occursin("FINAL",large["stdout"])
        cleanup_processes!(t.manager,ctx.session_id)
        @test isempty(t.manager.handles)
    end
end

@testset "Agent repairs a failing Python test with real tool execution" begin
    mktempdir() do root
        ctx=model_context(root)
        write(joinpath(root,"calc.py"),"def add(a, b):\n    return a - b\n")
        write(joinpath(root,"test_calc.py"),"import unittest\nfrom calc import add\nclass TestAdd(unittest.TestCase):\n    def test_add(self): self.assertEqual(add(2, 3), 5)\n")
        python=Sys.which("python")
        after_failure = req -> begin
            value=parsejson(req.messages[end].text)["value"]
            @test value["exit_code"]!=0
            @test occursin("FAILED",value["stderr"])
            response(;calls=[ToolCall("read",Dict("path"=>"calc.py"))])
        end
        after_read = req -> begin
            value=parsejson(req.messages[end].text)["value"]
            response(;calls=[ToolCall("edit",Dict("path"=>"calc.py","old"=>"a - b","new"=>"a + b","expected_sha256"=>value["sha256"]))])
        end
        after_pass = req -> begin
            value=parsejson(req.messages[end].text)["value"]
            @test value["exit_code"]==0
            @test occursin("OK",value["stderr"])
            response("Fixed add; the test passes.")
        end
        run_tests=response(;calls=[ToolCall("process",Dict("action"=>"run","argv"=>[python,"-B","-m","unittest"]))])
        rerun_tests=response(;calls=[ToolCall("process",Dict("action"=>"run","argv"=>[python,"-B","-m","unittest"]))])
        script=Any[run_tests,after_failure,after_read,rerun_tests,after_pass]
        provider=MockProvider(script)
        session=new_session(ctx;title="Fix add")
        final=run_agent!(provider,"Fix failing tests",ctx;session)
        @test final=="Fixed add; the test passes."
        @test session.status==:complete
        @test occursin("a + b",read(joinpath(root,"calc.py"),String))
        @test length(provider.requests)==5
        @test length(load_session(ctx.state_dir,session.id).messages)==10
        @test budget_status(ctx.budget)["reserved_tokens"]==0
    end
end
