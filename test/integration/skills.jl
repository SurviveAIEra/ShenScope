@testset "Actual agent lazily activates a Skill and narrows its next declarations" begin
    mktempdir() do root
        skill_fixture(joinpath(root, "skills"), "review-code"; frontmatter = "allowed-tools: [Read]\n", body = "ACTIVE INSTRUCTION SENTINEL: \$ARGUMENTS")
        config = Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => []))
        tools = core_tools(; config)
        ctx = skill_fixture_context(root)
        provider = MockProvider(Any[
            function (request)
                @test occursin("Available Skills metadata", request.messages[1].text)
                @test !occursin("ACTIVE INSTRUCTION SENTINEL", request.messages[1].text)
                @test any(tool -> tool["name"] == "process", request.tools)
                response(; calls = [ToolCall("activation", "skills", Dict("action" => "activate", "name" => "review-code", "arguments" => "Agent 中文"))])
            end,
            function (request)
                @test occursin("ACTIVE INSTRUCTION SENTINEL: Agent 中文", request.messages[1].text)
                @test Set(tool["name"] for tool in request.tools) == Set(["read", "skills"])
                response("Skill applied")
            end])
        @test run_agent!(provider, "Use the review skill", ctx; tools) == "Skill applied"
        @test length(provider.requests) == 2
        @test load_session(ctx.state_dir, ctx.session_id).metadata["active_skills"][1]["arguments"] == "Agent 中文"
        @test ctx.permissions.rules[:process] == Deny
    end
end

@testset "Headless Skills CLI reads shared references and preserves session state" begin
    mktempdir() do root
        skill_fixture(joinpath(root, "skills"), "review-code")
        config = deepcopy(ShenScope.DEFAULT_CONFIG); config["skills"] = Dict("project_roots" => ["skills"], "user_roots" => [])
        path = joinpath(root, "config.toml"); save_config!(config; path)
        ctx = skill_fixture_context(root); new_session(ctx)
        flags = ["--root", root, "--state-dir", ctx.state_dir, "--config", path]
        @test ShenScope.main(vcat(["skills", "list"], flags)) == 0
        @test ShenScope.main(vcat(["skills", "activate", "review-code", "CLI 中文", "--session", ctx.session_id, "--allow-persistence"], flags)) == 0
        @test load_session(ctx.state_dir, ctx.session_id).metadata["active_skills"][1]["arguments"] == "CLI 中文"
        @test ShenScope.main(vcat(["skills", "deactivate", "review-code", "--session", ctx.session_id, "--allow-persistence"], flags)) == 0
        @test isempty(load_session(ctx.state_dir, ctx.session_id).metadata["active_skills"])
        @test ShenScope.main(vcat(["skills", "activate", "review-code"], flags)) == 1
    end
end
