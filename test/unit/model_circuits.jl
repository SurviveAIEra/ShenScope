@testset "Circuit epochs reject stale completion and allow exactly one explicit recovery probe" begin
    mktempdir() do root
        now = Ref(0.0);manager = ModelCircuitManager(;clock=()->now[],max_history=4,max_leases=2)
        policy = ModelCircuitPolicy(;failure_threshold=1,cooldown=1.0,maximum_cooldown=4.0,max_in_flight=2)
        key = (root,joinpath(root,"state"),"source","private-scope")
        failing = ShenScope.acquire_model_circuit!(manager,key,policy)
        stale = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        @test_throws ArgumentError ShenScope.settle_model_circuit!(manager,failing,:failure;code=:permission)
        @test length(manager.entries[key].leases) == 2
        settled = ShenScope.settle_model_circuit!(manager,failing,:failure;code=:server)
        @test settled["health"]["state"] == "open" && settled["health"]["wait_seconds"] == 1
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        ignored = ShenScope.settle_model_circuit!(manager,stale,:success)
        @test !ignored["current_epoch"] && ignored["health"]["state"] == "open"
        @test ignored["health"]["consecutive_failures"] == 1 && ignored["health"]["last_outcome"] == "failure"
        @test ignored["health"]["successes"] == 1
        @test !ShenScope.settle_model_circuit!(manager,stale,:success)["settled"]
        now[] = 1.0;probe = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test probe.probe && manager.entries[key].state == :half_open
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        inconclusive = ShenScope.settle_model_circuit!(manager,probe,:neutral;code=:cancelled)
        @test inconclusive["health"]["state"] == "open" && inconclusive["health"]["wait_seconds"] == 0
        next = ShenScope.acquire_model_circuit!(manager,key,policy)
        failed = ShenScope.settle_model_circuit!(manager,next,:failure;code=:timeout)
        @test failed["health"]["state"] == "open" && failed["health"]["wait_seconds"] == 2
        now[] = 3.0;next = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test ShenScope.settle_model_circuit!(manager,next,:failure;code=:rate_limit)["health"]["wait_seconds"] == 4
        now[] = 7.0;next = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test ShenScope.settle_model_circuit!(manager,next,:failure;code=:transport)["health"]["wait_seconds"] == 4
        now[] = 11.0;next = ShenScope.acquire_model_circuit!(manager,key,policy)
        recovered = ShenScope.settle_model_circuit!(manager,next,:success)
        @test recovered["health"]["state"] == "closed" && recovered["health"]["consecutive_failures"] == 0
        @test recovered["health"]["last_failure_code"] === nothing
        @test length(recovered["health"]["history"]) == 4
        borrowed = ShenScope.acquire_model_circuit!(manager,key,policy)
        forged = ShenScope.ModelCircuitLease(borrowed.key,borrowed.id,borrowed.epoch,true)
        @test_throws ShenScopeError ShenScope.settle_model_circuit!(manager,forged,:success)
        @test length(manager.entries[key].leases) == 1
        @test ShenScope.settle_model_circuit!(manager,borrowed,:neutral;code=:custom_extension)["health"]["neutral_outcomes"] == 2
    end
end

@testset "Circuit admission reserves version capacity and does not reuse saturated CAS generations" begin
    mktempdir() do root
        manager=ModelCircuitManager();policy=ModelCircuitPolicy();key=(root,"state","source","versions")
        entry=ShenScope.new_model_circuit_entry(policy,ShenScope.model_circuit_clock(manager))
        manager.entries[key]=entry;entry.revision=typemax(Int)-4
        lease=ShenScope.acquire_model_circuit!(manager,key,policy)
        @test entry.revision == typemax(Int)-3
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        settled=ShenScope.settle_model_circuit!(manager,lease,:success)
        @test settled["health"]["revision"] == typemax(Int)-2 && isempty(entry.leases)
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        entry.revision=0;entry.epoch=typemax(Int)-1
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
        @test entry.epoch == typemax(Int)-1 && isempty(entry.leases)
    end
end

@testset "Concurrent recovery acquisition admits one probe and preserves every other caller" begin
    mktempdir() do root
        now=Ref(0.0);manager=ModelCircuitManager(;clock=()->now[])
        policy=ModelCircuitPolicy(;failure_threshold=1,cooldown=0.05)
        key=(root,"state","concurrent-source","private-scope")
        failed=ShenScope.acquire_model_circuit!(manager,key,policy)
        ShenScope.settle_model_circuit!(manager,failed,:failure;code=:server)
        now[]=0.05
        jobs=[Threads.@spawn try ShenScope.acquire_model_circuit!(manager,key,policy) catch error;error end for _ in 1:8]
        results=fetch.(jobs)
        leases=filter(result->result isa ShenScope.ModelCircuitLease,results)
        denied=filter(result->result isa ShenScopeError,results)
        @test length(leases) == 1 && length(denied) == 7
        @test all(error->error.code == :circuit_open,denied)
        @test length(manager.entries[key].leases) == 1
        @test ShenScope.settle_model_circuit!(manager,only(leases),:success)["health"]["state"] == "closed"
        @test isempty(manager.entries[key].leases)
    end
end

@testset "Circuit windows, neutral errors, disabled policy and global seats are distinct" begin
    mktempdir() do root
        now = Ref(0.0);manager = ModelCircuitManager(;clock=()->now[],max_sources=2,max_leases=1)
        policy = ModelCircuitPolicy(;failure_threshold=2,failure_window=1.0,cooldown=1.0)
        key = (root,"state","source","one");other = (root,"state","source","two")
        for instant in (0.0,2.0)
            now[] = instant;lease = ShenScope.acquire_model_circuit!(manager,key,policy)
            health = ShenScope.settle_model_circuit!(manager,lease,:failure;code=:server)["health"]
            @test health["state"] == "closed" && health["consecutive_failures"] == 1
        end
        lease = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,other,policy)
        @test ShenScope.settle_model_circuit!(manager,lease,:neutral;code=:authentication)["health"]["consecutive_failures"] == 1
        lease = ShenScope.acquire_model_circuit!(manager,key,policy)
        @test ShenScope.settle_model_circuit!(manager,lease,:success)["health"]["consecutive_failures"] == 0
        disabled = ModelCircuitPolicy(;enabled=false,failure_threshold=1)
        lease = ShenScope.acquire_model_circuit!(manager,other,disabled)
        health = ShenScope.settle_model_circuit!(manager,lease,:failure;code=:server)["health"]
        @test health["state"] == "disabled" && health["consecutive_failures"] == 0 && health["failures"] == 1
        @test health["last_outcome"] == "failure"
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,(root,"state","source","capacity"),policy)
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,other,policy)
        lease = ShenScope.acquire_model_circuit!(manager,key,policy)
        ShenScope.close_model_circuits!(manager)
        @test ShenScope.settle_model_circuit!(manager,lease,:success)["reason"] == "retired"
        @test_throws ShenScopeError ShenScope.acquire_model_circuit!(manager,key,policy)
    end
end

@testset "Health metadata scopes credentials and resets with CAS without claiming a network probe" begin
    mktempdir() do root
        now = Ref(0.0);key = Ref("health-private-fixture")
        runtime = ModelProviderRuntime(;circuits=ModelCircuitManager(;clock=()->now[],max_sources=2),
            circuit_policy=ModelCircuitPolicy(;failure_threshold=1,cooldown=1.0))
        provider = HTTPProvider(ProviderConfig(;endpoint="http://127.0.0.1:1"),variable->key[];runtime)
        ctx = model_context(root)
        initial = model_health_snapshot(provider,ctx)
        @test initial["revision"] == 0 && !initial["tracked"] && !initial["network_probe_performed"]
        scope = ShenScope.model_circuit_key(provider,ShenScope.CredentialSnapshot(key[]),ctx)
        lease = ShenScope.acquire_model_circuit!(runtime.circuits,scope,runtime.circuit_policy)
        @test_throws ShenScopeError reset_model_health!(provider,ctx;expected_revision=1)
        ShenScope.settle_model_circuit!(runtime.circuits,lease,:failure;code=:server)
        snapshot = model_health_snapshot(provider,ctx)
        @test snapshot["state"] == "open"
        @test !occursin(key[],canonical(snapshot)) && !occursin(scope[end],canonical(snapshot))
        @test !occursin(runtime.circuits.salt,sprint(show,provider))
        @test_throws ShenScopeError reset_model_health!(provider,ctx;expected_revision=0)
        reset = reset_model_health!(provider,ctx;expected_revision=snapshot["revision"])
        @test reset["state"] == "closed" && reset["reset"] && !reset["reset_is_health_probe"]
        reset["history"][1]["event"] = "modified"
        @test model_health_snapshot(provider,ctx)["history"][1]["event"] != "modified"
        key[] = "rotated-health-fixture"
        @test !model_health_snapshot(provider,ctx)["tracked"]
        key[] = "health-private-fixture"
        current = model_health_snapshot(provider,ctx)
        @test reset_model_health!(provider,ctx;expected_revision=current["revision"],clear=true)["revision"] == 0
        @test isempty(runtime.circuits.entries)
        other = RuntimeContext(root;state_dir=joinpath(root,"other-state"))
        @test !model_health_snapshot(provider,other)["tracked"]
        ctx.permissions.rules[:read] = Deny
        @test_throws ShenScopeError model_health_snapshot(provider,ctx)
    end
end
