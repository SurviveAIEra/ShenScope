using ShenScope: WorkReady, WorkPending, WorkRunning, WorkRetryWaiting, WorkSucceeded,
    WorkFailed, WorkBlocked, WorkCancelled, WorkUncertain

function work_context(root; session_id = "owner", rules = nothing)
    policy = PermissionPolicy(; rules = rules === nothing ?
        Dict(:read => Allow, :edit => Allow, :process => Allow, :persistence => Allow, :network => Allow) : rules)
    RuntimeContext(root; session_id, state_dir = joinpath(root, "state"), permissions = policy)
end
read_work(id; kwargs...) = WorkSpec(id, :tool, "read", Dict("path" => "source.txt"); kwargs...)

@testset "Task definition validation and independent graph checks" begin
    mktempdir() do root
        ctx = work_context(root)
        @test_throws ShenScopeError create_workflow(ctx, WorkSpec[])
        @test_throws ShenScopeError create_workflow(ctx, [read_work("a"), read_work("a")])
        @test_throws ShenScopeError create_workflow(ctx, [read_work("a"; dependencies = ["absent"])])
        @test_throws ShenScopeError create_workflow(ctx, [read_work("a"; dependencies = ["b"]), read_work("b"; dependencies = ["a"])])
        @test_throws ShenScopeError create_workflow(ctx, [read_work("a"; deduplication_key = "same"), read_work("b"; deduplication_key = "same")])
        @test_throws ShenScopeError read_work("a"; dependencies = ["a"])
        @test_throws ShenScopeError read_work("a"; timeout = true)
        @test_throws ShenScopeError read_work("a"; priority = true)
        @test_throws ShenScopeError WorkSpec("a", :tool, "write", Dict("path" => "x", "content" => "x"); safe_retry = true)
        @test_throws ShenScopeError WorkSpec("a", :model, "agent", Dict("prompt" => "x", "api_key" => "forbidden"))
        @test_throws ShenScopeError ShenScope.work_spec_from(Dict("id" => "x", "kind" => "tool", "operation" => "read", "arguments" => Dict(), "invented" => true))
        @test_throws ShenScopeError ShenScope.retry_policy_from(Dict("max_attempts" => true))
        bound = WorkSpec("b", :tool, "write", Dict("path" => "out", "content" => Dict("\$task_result" => "a", "path" => ["text"])) ; dependencies = ["a"])
        workflow = create_workflow(ctx, [read_work("a"), bound]; id = "graph")
        @test workflow.topological_order == ["a", "b"]
        invalid = WorkSpec("c", :tool, "write", Dict("path" => "out", "content" => Dict("\$task_result" => "a")))
        @test_throws ShenScopeError create_workflow(ctx, [read_work("a"), invalid])
        @test workflow_status(workflow, ctx)["counts"]["pending"] == 1
    end
end

@testset "Claims, dependency release, priority, fences and detached views" begin
    mktempdir() do root
        ctx = work_context(root)
        workflow = create_workflow(ctx, [read_work("low"), read_work("high"; priority = 10), read_work("after"; dependencies = ["high"])]; id = "claims")
        independent = load_workflow(ctx, workflow.id)
        claimed = claim_work!(workflow, ctx; worker = "first", now = 100.0, lease_seconds = 10.0)
        @test claimed.spec.id == "high"
        other = claim_work!(independent, ctx; worker = "second", now = 100.0, lease_seconds = 10.0)
        @test other.spec.id == "low"
        @test claim_work!(workflow, ctx; worker = "third", now = 100.0) === nothing
        @test_throws ShenScopeError finish_work!(workflow, ctx, "high"; worker = "first", token = claimed.lease.token, now = 101.0)
        start_work!(workflow, ctx, "high"; worker = "first", token = claimed.lease.token, now = 101.0)
        @test_throws ShenScopeError start_work!(workflow, ctx, "high"; worker = "first", token = claimed.lease.token, now = 101.0)
        @test_throws ShenScopeError finish_work!(workflow, ctx, "high"; worker = "second", token = claimed.lease.token, now = 102.0)
        heartbeat_work!(workflow, ctx, "high"; worker = "first", token = claimed.lease.token, now = 102.0, lease_seconds = 20)
        finish_work!(workflow, ctx, "high"; worker = "first", token = claimed.lease.token, result = Dict("text" => "verified"), now = 111.0)
        @test load_workflow(ctx, workflow.id).tasks["after"].status == WorkReady
        @test materialize_work_result(workflow, workflow.tasks["high"], ctx) == Dict("text" => "verified")
        view = workflow_task(workflow, ctx, "high")
        view["definition"]["arguments"]["path"] = "tampered"
        view["result"]["text"] = "tampered"
        @test workflow.tasks["high"].spec.arguments["path"] == "source.txt"
        @test workflow.tasks["high"].result["text"] == "verified"
        @test !occursin(claimed.lease.token, canonical(workflow_tasks(workflow, ctx)))
        @test isempty(workflow_tasks(workflow, ctx; offset = 100)["items"])
        @test_throws ShenScopeError cancel_work!(workflow, ctx, ["after"]; expected_revision = 1)
    end
end

@testset "Safe retries, uncertain effects and explicit reconciliation" begin
    mktempdir() do root
        ctx = work_context(root)
        retry = WorkRetryPolicy(; max_attempts = 3, initial_delay = 2.0, maximum_delay = 10.0, jitter_fraction = 0.0)
        unsafe = WorkSpec("write", :tool, "write", Dict("path" => "out", "content" => "x"); retry)
        workflow = create_workflow(ctx, [unsafe, read_work("after"; dependencies = ["write"])]; id = "uncertain")
        claim = claim_work!(workflow, ctx; worker = "old", now = 10.0, lease_seconds = 1.0)
        start_work!(workflow, ctx, "write"; worker = "old", token = claim.lease.token, now = 10.1)
        recover_workflow!(workflow, ctx; now = 12.0)
        @test workflow.tasks["write"].status == WorkUncertain
        @test workflow.tasks["after"].status == WorkPending
        @test workflow_status(workflow, ctx)["status"] == "needs_reconciliation"
        @test claim_work!(workflow, ctx; worker = "new", now = 12.0) === nothing
        @test_throws ShenScopeError finish_work!(workflow, ctx, "write"; worker = "old", token = claim.lease.token, now = 12.0)
        @test_throws ShenScopeError reconcile_work!(workflow, ctx, "write"; disposition = :succeeded, evidence = "")
        @test_throws ShenScopeError reconcile_work!(workflow, ctx, "write"; disposition = :succeeded, evidence = "file verified", expected_version = 1)
        reconcile_work!(workflow, ctx, "write"; disposition = :succeeded, evidence = "file verified by hash", result = Dict("sha" => "checked"), now = 13.0)
        @test workflow.tasks["after"].status == WorkReady
        safe = create_workflow(ctx, [read_work("safe"; safe_retry = true, retry)]; id = "retry")
        first = claim_work!(safe, ctx; worker = "one", now = 10.0, lease_seconds = 1)
        start_work!(safe, ctx, "safe"; worker = "one", token = first.lease.token, now = 10.1)
        recover_workflow!(safe, ctx; now = 12.0)
        @test safe.tasks["safe"].status == WorkRetryWaiting
        @test safe.tasks["safe"].not_before == 14.0
        @test claim_work!(safe, ctx; worker = "two", now = 13.0) === nothing
        second = claim_work!(safe, ctx; worker = "two", now = 14.0)
        @test second.attempts == 2
        @test second.lease.token != first.lease.token
        @test_throws ShenScopeError heartbeat_work!(safe, ctx, "safe"; worker = "one", token = first.lease.token, now = 14.0)
        start_work!(safe, ctx, "safe"; worker = "two", token = second.lease.token, now = 14.1)
        finish_work!(safe, ctx, "safe"; worker = "two", token = second.lease.token,
            failure = WorkFailure(:input, "Invalid path", false, false), now = 15.0)
        @test safe.tasks["safe"].status == WorkFailed
        @test length(safe.tasks["safe"].receipts) == 2
    end
end

@testset "Exclusive effects, cancellation propagation and read-only recovery" begin
    mktempdir() do root
        ctx = work_context(root)
        unsafe = WorkSpec("write", :tool, "write", Dict("path" => "out", "content" => "x"); priority = 10)
        workflow = create_workflow(ctx, [unsafe, read_work("read"), read_work("dependent"; dependencies = ["write"])]; id = "cancel")
        claim = claim_work!(workflow, ctx; worker = "owner", now = 10.0)
        @test claim.spec.id == "write"
        @test claim_work!(workflow, ctx; worker = "other", now = 10.0) === nothing
        cancel_work!(workflow, ctx, ["write"])
        @test workflow.tasks["write"].cancel_requested
        @test workflow.tasks["dependent"].status == WorkCancelled
        @test_throws ShenScopeError start_work!(workflow, ctx, "write"; worker = "owner", token = claim.lease.token, now = 10.1)
        recover_workflow!(workflow, ctx; now = 50.0)
        @test workflow.tasks["write"].status == WorkCancelled
        path = workflow.journal.path
        good_size = filesize(path)
        open(io -> write(io, "{torn"), path, "a")
        loaded = load_workflow(ctx, workflow.id)
        @test loaded.revision == workflow.revision
        @test filesize(path) == good_size + 5
        foreign = work_context(root; session_id = "foreign")
        @test_throws ShenScopeError load_workflow(foreign, workflow.id)
        @test filesize(path) == good_size + 5
        denied = work_context(root; rules = Dict(:read => Allow, :persistence => Deny))
        @test_throws ShenScopeError recover_workflow!(loaded, denied; now = 60.0)
        @test filesize(path) == good_size + 5
        recover_workflow!(loaded, ctx; now = 60.0)
        @test filesize(path) == good_size
        @test list_workflows(foreign)["total"] == 0
        shared = create_workflow(ctx, [read_work("a")]; id = "shared", scope = :workspace)
        @test load_workflow(foreign, shared.id).scope == :workspace
        @test list_workflows(foreign)["total"] == 1
    end
end

@testset "Large result artifacts, digest verification and descriptor collisions" begin
    mktempdir() do root
        ctx = work_context(root)
        workflow = create_workflow(ctx, [read_work("a")]; id = "result")
        claimed = claim_work!(workflow, ctx; worker = "worker")
        start_work!(workflow, ctx, "a"; worker = "worker", token = claimed.lease.token)
        result = Dict("text" => repeat("中文", 30000))
        finish_work!(workflow, ctx, "a"; worker = "worker", token = claimed.lease.token, result)
        loaded = load_workflow(ctx, workflow.id)
        @test ShenScope.work_result_reference(loaded.tasks["a"].result)
        @test materialize_work_result(loaded, loaded.tasks["a"], ctx) == result
        descriptor = loaded.tasks["a"].result
        artifact = ShenScope.work_result_path(loaded, descriptor["sha256"])
        @test stat(artifact).mode & 0o777 == 0o600
        open(io -> write(io, "x"), artifact, "a")
        @test_throws ShenScopeError materialize_work_result(loaded, loaded.tasks["a"], ctx)
        @test_throws ShenScopeError ShenScope.serialize_work_result(repeat("x", ShenScope.MAX_WORK_RESULT_BYTES + 1))
        @test_throws ShenScopeError workflow_tasks(loaded, ctx; limit = true)
    end
end
