function skill_fixture(root, name; body = "Use inspected evidence. \$ARGUMENTS", frontmatter = "", directory = name)
    folder = joinpath(root, directory)
    mkpath(folder)
    path = joinpath(folder, "SKILL.md")
    write(path, "---\nname: " * name * "\ndescription: Review changes with evidence\n" * frontmatter * "---\n" * body)
    path
end

function skill_fixture_context(root; session_id = "skills-owner", state_dir = joinpath(root, "state"), sink = event -> nothing)
    RuntimeContext(root; session_id, state_dir, sink,
        permissions = PermissionPolicy(; rules = Dict(:read => Allow, :persistence => Allow, :edit => Deny, :process => Deny, :network => Deny)))
end

@testset "Skills YAML metadata is bounded, typed and independently validated" begin
    raw = "\ufeff---\r\nname: review-code\r\ndescription: >\r\n  Review a change\r\n  using evidence\r\nmetadata:\r\n  owner: '中文'\r\n  labels: [julia, tests]\r\nallowed-tools: [Read, Grep]\r\n---\r\nBody text\r\n"
    metadata, body = ShenScope.skill_frontmatter(raw)
    @test strip(metadata["description"]) == "Review a change using evidence"
    @test metadata["metadata"]["owner"] == "中文"
    @test body == "Body text\n"
    manifest = ShenScope.skill_manifest(raw, "/fixture/review-code/SKILL.md", :project)
    @test manifest.allowed_tools == ["read", "search"]
    @test manifest.sha256 == digest(raw)
    @test manifest.scope == :project
    for header in ["name: a\nname: b\ndescription: dup", "name: &x review\ndescription: *x", "name: review\ndescription: !!str unsafe", "name: review\ndescription: .nan", "name: Review\ndescription: invalid", "name: review\ndescription: valid\ndisable-model-invocation: 'true'", "name: review\ndescription: valid\nallowed-tools: ['Bash(git *)']", "name: review\ndescription: valid\n1: invalid"]
        @test_throws ShenScopeError ShenScope.skill_manifest("---\n" * header * "\n---\nbody", "/fixture/SKILL.md", :project)
    end
    @test_throws ShenScopeError ShenScope.skill_frontmatter("No frontmatter")
    @test_throws ShenScopeError ShenScope.skill_frontmatter("---\nname: review\n")
    @test_throws ShenScopeError ShenScope.skill_frontmatter("---\nname: review\ndescription: " * repeat("x", 17000) * "\n---")
    @test_throws ShenScopeError ShenScope.skill_frontmatter("---\nmetadata: " * repeat("[", 18) * "1" * repeat("]", 18) * "\n---")
    @test_throws ShenScopeError skill_config(Dict("skills" => Dict("unknown" => true)))
    @test_throws ShenScopeError skill_config(Dict("skills" => Dict("user_roots" => ["relative"])))
    @test_throws ShenScopeError skill_config(Dict("skills" => Dict("max_depth" => true)))
end

@testset "Skills discovery preserves sources, precedence, diagnostics and lazy bodies" begin
    mktempdir() do outer
        project = joinpath(outer, "project"); user = joinpath(outer, "user"); mkpath(project); mkpath(user)
        path = skill_fixture(joinpath(project, "skills"), "review-code"; body = "PROJECT BODY SENTINEL")
        skill_fixture(user, "review-code"; body = "USER BODY SENTINEL")
        skill_fixture(joinpath(project, "skills"), "parent"; directory = "nested/parent")
        skill_fixture(joinpath(project, "skills", "nested", "parent"), "hidden-child")
        skill_fixture(joinpath(project, "skills", "node_modules"), "dependency")
        mkpath(joinpath(project, "skills", "broken")); write(joinpath(project, "skills", "broken", "SKILL.md"), "invalid")
        manager = SkillManager(Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => [user])))
        ctx = skill_fixture_context(project)
        snapshot = skills_list(manager, ctx)
        @test length(snapshot["skills"]) == 3
        @test [row["scope"] for row in snapshot["skills"] if row["name"] == "review-code"] == ["project", "user"]
        @test count(row -> row["selected"], snapshot["skills"]) == 2
        @test !occursin("BODY SENTINEL", canonical(snapshot))
        @test any(row -> row["code"] == "skill_frontmatter", snapshot["diagnostics"])
        @test any(row -> row["code"] == "skill_shadowed", snapshot["diagnostics"])
        @test ShenScope.skill_resolve(manager, ctx, "review-code").path == path
        @test isempty(manager.active)
        first_generation = snapshot["generation"]
        @test skills_list(manager, ctx; reload = true)["generation"] == first_generation + 1
        ctx.permissions.rules[:read] = Deny
        @test_throws ShenScopeError skills_list(manager, ctx)
        small = SkillManager(Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => [], "max_skills" => 1)))
        @test skills_list(small, skill_fixture_context(project))["truncated"]
        @test length(small.catalogs[realpath(project)].manifests) == 1
    end
end

@testset "Skills activation, resource confinement, replay and permission boundaries" begin
    mktempdir() do root
        path = skill_fixture(joinpath(root, "skills"), "review-code"; frontmatter = "allowed-tools: [Read]\n")
        skill_fixture(joinpath(root, "skills"), "manual"; frontmatter = "disable-model-invocation: true\n")
        manager = SkillManager(Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => [])))
        ctx = skill_fixture_context(root)
        session = new_session(ctx)
        bind_skills_session!(manager, session, ctx)
        snapshot = skills_list(manager, ctx)
        manifest = ShenScope.skill_resolve(manager, ctx, "review-code")
        @test_throws ShenScopeError activate_skill!(manager, "manual", ctx)
        activated = activate_skill!(manager, "review-code", ctx; arguments = "中文参数", expected_sha256 = manifest.sha256)
        @test occursin("中文参数", activated["body"])
        @test load_session(ctx.state_dir, ctx.session_id).metadata["active_skills"][1]["sha256"] == manifest.sha256
        add_message!(session, Message(:user, "Session revision stays current"))
        @test load_session(ctx.state_dir, ctx.session_id).messages[end].text == "Session revision stays current"
        @test Set(tool_name.(ShenScope.skill_filter_tools(manager, core_tools(), ctx))) == Set(["read", "skills"])
        @test ctx.permissions.rules[:process] == Deny
        @test !any(grant -> grant[1] in (:edit, :process, :network), ctx.permissions.grants)
        @test count(row -> row["loaded"], skills_list(manager, ctx)["skills"]) == 1
        restored = SkillManager(Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => [])))
        replay_session = load_session(ctx.state_dir, ctx.session_id)
        restore_skills!(restored, replay_session, ctx)
        @test length(restored.active[(ctx.root, ctx.session_id)]) == 1
        @test occursin("中文参数", ShenScope.skill_model_context(restored, replay_session, ctx))
        peer = skill_fixture_context(root; session_id = "skills-peer")
        @test all(!row["loaded"] for row in skills_list(manager, peer)["skills"])
        write(joinpath(dirname(path), "reference.txt"), "Reference evidence")
        @test skill_read_resource(manager, "review-code", "reference.txt", ctx)["text"] == "Reference evidence"
        write(joinpath(root, "outside.txt"), "outside")
        @test_throws ShenScopeError skill_read_resource(manager, "review-code", "../../outside.txt", ctx)
        write(joinpath(dirname(path), ".env"), "protected")
        @test_throws ShenScopeError skill_read_resource(manager, "review-code", ".env", ctx)
        symlink(joinpath(dirname(path), "reference.txt"), joinpath(dirname(path), "link.txt"))
        @test_throws ShenScopeError skill_read_resource(manager, "review-code", "link.txt", ctx)
        write(path, read(path, String) * "\nChanged instructions")
        @test_throws ShenScopeError activate_skill!(manager, "review-code", ctx)
        @test !occursin("Changed instructions", ShenScope.skill_model_context(manager, session, ctx))
        skills_list(manager, ctx; reload = true)
        @test all(!row["loaded"] for row in skills_list(manager, ctx)["skills"])
        activate_skill!(manager, "manual", ctx; user_requested = true)
        @test length(deactivate_skill!(manager, "manual", ctx)["deactivated"]) == 1
        ctx.permissions.rules[:persistence] = Deny
        @test_throws ShenScopeError activate_skill!(manager, "review-code", ctx)
        @test isempty(manager.active[(ctx.root, ctx.session_id)])
        ctx.permissions.rules[:read] = Deny
        @test ShenScope.skill_model_context(manager, session, ctx) == ""
    end
end

@testset "Skills source revisions are rechecked after approval" begin
    mktempdir() do root
        path = skill_fixture(joinpath(root, "skills"), "review-code")
        ctx = skill_fixture_context(root); session = new_session(ctx)
        manager = SkillManager(Dict("skills" => Dict("project_roots" => ["skills"], "user_roots" => [])))
        bind_skills_session!(manager, session, ctx)
        ctx.permissions.rules[:persistence] = Ask
        ctx.approve = request -> begin
            write(path, read(path, String) * "\nChanged during approval")
            :once
        end
        @test_throws ShenScopeError activate_skill!(manager, "review-code", ctx)
        @test isempty(get(load_session(ctx.state_dir, ctx.session_id).metadata, "active_skills", []))
        @test isempty(get(manager.active, (ctx.root, ctx.session_id), Dict()))
    end
end
