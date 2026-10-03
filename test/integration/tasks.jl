@testset "Actual worker DAG binds verified dependency results" begin
    mktempdir() do root
        write(joinpath(root, "source.txt"), "Julia workers\n")
        ctx = work_context(root)
        bound = WorkSpec("write", :tool, "write", Dict("path" => "output.txt",
            "content" => Dict("\$task_result" => "read", "path" => ["text"])) ; dependencies = ["read"])
        workflow = create_workflow(ctx, [read_work("read"), bound]; id = "actual")
        executor = WorkExecutor()
        result = run_workflow!(executor, workflow, ctx; concurrency = 3)
        @test result["status"] == "succeeded"
        @test read(joinpath(root, "output.txt"), String) == "1: Julia workers\n2: "
        @test length(workflow.tasks["write"].receipts) == 1
        @test load_workflow(ctx, workflow.id).tasks["read"].status == WorkSucceeded
        @test !haskey(executor.tools, "tasks")
    end
end

@testset "Test processes, timeout uncertainty and separate model sessions" begin
    mktempdir() do root
        ctx = work_context(root)
        testwork = WorkSpec("test", :test, "process", Dict("action" => "run", "argv" => ["/bin/sh", "-c", "printf verified"] ))
        workflow = create_workflow(ctx, [testwork]; id = "process")
        @test run_workflow!(WorkExecutor(), workflow, ctx)["status"] == "succeeded"
        @test workflow.tasks["test"].result["stdout"] == "verified"
        failed = WorkSpec("test", :test, "process", Dict("action" => "run", "argv" => ["/bin/sh", "-c", "exit 7"]))
        failure = create_workflow(ctx, [failed]; id = "failed")
        @test run_workflow!(WorkExecutor(), failure, ctx)["status"] == "failed"
        @test failure.tasks["test"].failure.code == :test_failed
        slow = WorkSpec("test", :test, "process", Dict("action" => "run", "argv" => ["/bin/sh", "-c", "sleep 10"]); timeout = 0.2)
        timeout = create_workflow(ctx, [slow]; id = "timeout")
        started = time()
        @test run_workflow!(WorkExecutor(), timeout, ctx)["status"] == "needs_reconciliation"
        @test time() - started < 5
        model = WorkSpec("agent", :model, "agent", Dict("prompt" => "Say hello"))
        modelworkflow = create_workflow(ctx, [model]; id = "model")
        executor = WorkExecutor(; provider_factory = ctx -> MockProvider([response("你好 Julia")]))
        @test run_workflow!(executor, modelworkflow, ctx)["status"] == "succeeded"
        output = modelworkflow.tasks["agent"].result
        @test output["text"] == "你好 Julia"
        @test output["session_id"] != ctx.session_id
        @test load_session(ctx.state_dir, output["session_id"]).metadata["workflow_id"] == "model"
        @test budget_status(ctx.budget)["steps"] > 0
        large = WorkSpec("large", :test, "process", Dict("action" => "run", "argv" =>
            ["/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\000' 'x'"]))
        archived = create_workflow(ctx, [large]; id = "large-process")
        @test run_workflow!(WorkExecutor(), archived, ctx)["status"] == "succeeded"
        @test ShenScope.work_result_reference(archived.tasks["large"].result)
        @test ncodeunits(workflow_task(archived, ctx, "large"; materialize = true)["result"]["stdout"]) == 200000
        background = WorkSpec("background", :tool, "process", Dict("action" => "start", "argv" => ["/bin/sh", "-c", "sleep 10"]))
        invalid = create_workflow(ctx, [background]; id = "background")
        @test run_workflow!(WorkExecutor(), invalid, ctx)["status"] == "failed"
        @test invalid.tasks["background"].failure.code == :arguments
    end
end

@testset "Two real Julia processes cannot claim the same task" begin
    mktempdir() do root
        ctx = work_context(root)
        workflow = create_workflow(ctx, [read_work("a")]; id = "race")
        script = joinpath(root, "claim.jl")
        write(script, """
            using ShenScope
            ctx = RuntimeContext(ARGS[1]; session_id="owner", state_dir=joinpath(ARGS[1], "state"),
                permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow)))
            workflow = load_workflow(ctx, "race")
            while !isfile(joinpath(ARGS[1], "go")); sleep(0.005); end
            result = claim_work!(workflow, ctx; worker=ARGS[2], lease_seconds=60)
            write(joinpath(ARGS[1], ARGS[2] * ".result"), result === nothing ? "empty" : result.spec.id)
            """)
        commands = [Cmd([joinpath(Sys.BINDIR, "julia"), "--project=" * dirname(@__DIR__) * "/..", script, root, worker]) for worker in ("first", "second")]
        processes = [run(pipeline(command; stdout=devnull, stderr=devnull); wait=false) for command in commands]
        try
            write(joinpath(root, "go"), "go")
            foreach(wait, processes)
            @test all(success, processes)
            @test sort!([read(joinpath(root, worker * ".result"), String) for worker in ("first", "second")]) == ["a", "empty"]
            @test load_workflow(ctx, workflow.id).tasks["a"].attempts == 1
        finally
            for process in processes; process_exited(process) || kill(process); end
        end
    end
end

@testset "Agent and headless CLI invoke the same durable task tool" begin
    mktempdir() do root
        write(joinpath(root, "source.txt"), "shared Core\n")
        ctx = work_context(root)
        definition = Dict("workflow_id" => "agent-tool", "definitions" => [ShenScope.work_spec_dict(read_work("read"))])
        provider = MockProvider([
            response(; calls = [ToolCall("tasks", merge(definition, Dict("action" => "create")))]),
            response(; calls = [ToolCall("tasks", Dict("action" => "run", "workflow_id" => "agent-tool"))]),
            response("Task result verified")])
        @test run_agent!(provider, "Read through a task graph", ctx) == "Task result verified"
        @test load_workflow(ctx, "agent-tool").tasks["read"].status == WorkSucceeded
        cli_definition = joinpath(root, "workflow.json")
        write(cli_definition, canonical(Dict("workflow_id" => "cli-tool", "definitions" => definition["definitions"])))
        flags = ["--root", root, "--state-dir", ctx.state_dir, "--config", joinpath(root, "config.toml"), "--session", "cli-owner", "--allow-persistence"]
        @test ShenScope.main(["tasks", "create", cli_definition, flags...]) == 0
        @test ShenScope.main(["tasks", "run", "cli-tool", flags...]) == 0
        @test ShenScope.main(["tasks", "get", "cli-tool", "read", flags...]) == 0
        cli_context = work_context(root; session_id = "cli-owner")
        @test load_workflow(cli_context, "cli-tool").tasks["read"].status == WorkSucceeded
    end
end
