@testset "Saved proposals survive restart and require fresh source checks and a new apply" begin
    mktempdir() do root
        ctx, manager, files = workspace_fixture(root)
        ctx.permissions.rules[:persistence] = Allow
        plan = prepare_workspace_edits!(manager, ctx, files)
        store = workspace_history_store(ctx)
        saved = save_workspace_history!(store, manager, plan["plan_id"], ctx;
            expected_plan_sha256=plan["plan_sha256"], expected_version=0)
        @test saved["version"] == 1 && !saved["source_backups_saved"]
        @test_throws ShenScopeError save_workspace_history!(store, manager, plan["plan_id"], ctx;
            expected_plan_sha256=plan["plan_sha256"], expected_version=0)
        close_workspace_edits!(manager)
        restarted = workspace_history_store(ctx)
        @test length(list_workspace_history(restarted, ctx)["history"]) == 1
        history = read_workspace_history(restarted, saved["history_id"], ctx; expected_version=1)
        @test history["record"]["plan_sha256"] == plan["plan_sha256"] && history["evidence_is_historical"]
        @test inspect_workspace_history_sources(restarted, saved["history_id"], ctx; expected_version=1)["all_files_match_before"]
        next = WorkspaceEditManager()
        restored = restore_workspace_proposal!(restarted, next, saved["history_id"], ctx;
            expected_version=1, expected_record_sha256=saved["record_sha256"])
        proposal = restored["proposal"]
        @test proposal["plan_id"] != plan["plan_id"] && restored["requires_new_apply"]
        @test occursin("old", read(joinpath(root,"a.py"), String)) && !restored["workspace_files_modified"]
        receipt = apply_workspace_edits!(next, proposal["plan_id"], ctx; expected_plan_sha256=proposal["plan_sha256"])
        @test receipt["outcome"] == "applied"
        @test_throws ShenScopeError restore_workspace_proposal!(restarted, WorkspaceEditManager(), saved["history_id"], ctx;
            expected_version=1, expected_record_sha256=saved["record_sha256"])
        after = inspect_workspace_history_sources(restarted, saved["history_id"], ctx; expected_version=1)
        @test after["all_files_match_after"] && !after["source_identity_proves_command_success"]
        write(joinpath(root,"a.py"), "external new change\n")
        drift = inspect_workspace_history_sources(restarted, saved["history_id"], ctx; expected_version=1)
        @test !drift["all_files_match_after"] && any(row->row["source_state"]=="changed", drift["files"])
    end
end

@testset "History owns receipts, refuses tampering, enforces CAS and preserves files on deletion" begin
    mktempdir() do root
        ctx, manager, files = workspace_fixture(root)
        ctx.permissions.rules[:persistence] = Allow
        plan = prepare_workspace_edits!(manager, ctx, files)
        receipt = apply_workspace_edits!(manager, plan["plan_id"], ctx; expected_plan_sha256=plan["plan_sha256"])
        store = workspace_history_store(ctx)
        saved = save_workspace_history!(store, manager, plan["plan_id"], ctx;
            expected_plan_sha256=plan["plan_sha256"], expected_version=0)
        record = read_workspace_history(store, saved["history_id"], ctx; expected_version=1)
        @test record["record"]["receipt"]["sha256"] == receipt["sha256"]
        @test_throws ShenScopeError restore_workspace_proposal!(store, WorkspaceEditManager(), saved["history_id"], ctx;
            expected_version=1, expected_record_sha256=saved["record_sha256"])
        corrupt = deepcopy(record["record"])
        corrupt["proposals"][1]["edits"][1]["new_text"] = "forged"
        @test_throws ShenScopeError ShenScope.workspace_history_record(corrupt, ctx, store.limits)
        foreign = RuntimeContext(root; session_id="foreign", state_dir=ctx.state_dir)
        @test_throws ShenScopeError list_workspace_history(store, foreign)
        ctx.permissions.rules[:persistence] = Deny
        @test_throws ShenScopeError remove_workspace_history!(store, saved["history_id"], ctx; expected_version=1)
        ctx.permissions.rules[:persistence] = Allow
        @test_throws ShenScopeError read_workspace_history(store, saved["history_id"], ctx; expected_version=2)
        deleted = remove_workspace_history!(store, saved["history_id"], ctx; expected_version=1)
        @test deleted["version"] == 2 && !deleted["workspace_files_modified"]
        @test isempty(list_workspace_history(store, ctx)["history"])
        @test occursin("new", read(joinpath(root,"b.js"), String))
        @test_throws ShenScopeError read_workspace_history(store, saved["history_id"], ctx)
        ctx.permissions.rules[:read] = Deny
        @test_throws ShenScopeError list_workspace_history(store, ctx)
    end
end

@testset "History has bounded records and stores no complete source backups" begin
    mktempdir() do root
        ctx, manager, files = workspace_fixture(root)
        ctx.permissions.rules[:persistence] = Allow
        plan = prepare_workspace_edits!(manager, ctx, files)
        tiny = workspace_history_store(ctx; limits=WorkspaceHistoryLimits(; maximum_record_bytes=1024))
        @test_throws ShenScopeError save_workspace_history!(tiny, manager, plan["plan_id"], ctx;
            expected_plan_sha256=plan["plan_sha256"], expected_version=0)
        @test !isfile(tiny.store.journal.path)
        store = workspace_history_store(ctx)
        saved = save_workspace_history!(store, manager, plan["plan_id"], ctx;
            expected_plan_sha256=plan["plan_sha256"], expected_version=0)
        text = read(store.store.journal.path, String)
        @test !occursin("value =", text) && !occursin("const value", text)
        @test filesize(store.store.journal.path) < 10*1024
        @test saved["survives_restart"] && !saved["automatic_execution"]
    end
end
