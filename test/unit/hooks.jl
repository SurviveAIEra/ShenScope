function hook_entry(;name="guard", point="before_tool", argv=["python3", "-c", "print('{}')"], kwargs...)
    merge(Dict{String,Any}("name"=>name, "point"=>point, "argv"=>argv), Dict{String,Any}(String(key)=>value for (key, value) in kwargs))
end
hook_test_config(entries=[];kwargs...) = Dict("hooks"=>merge(Dict{String,Any}("entries"=>entries,"project_files"=>[],"user_files"=>[]), Dict(String(key)=>value for (key, value) in kwargs)))

function hook_file(root, entries;name="hooks.toml")
    path=joinpath(root, name);mkpath(dirname(path))
    open(path, "w") do file; ShenScope.TOML.print(file, Dict("hooks"=>entries)); end
    path
end

@testset "Hooks configuration has explicit points, bounds and no permission grants" begin
    config=hook_test_config([hook_entry()])
    @test hook_config(config).entries[1]["name"] == "guard"
    @test hook_point("after_edit") == ShenScope.HookAfterEdit
    @test_throws ShenScopeError hook_point("PermissionAllow")
    invalid=[hook_entry(argv=[]),hook_entry(argv=["python3", "\0"]),hook_entry(timeout=true),
        hook_entry(timeout=Inf),hook_entry(timeout=301),hook_entry(output_limit=0),hook_entry(point="after_edit",on_failure="deny"),
        hook_entry(enabled="true"),hook_entry(name="UpperCase"),hook_entry(on_failure="allow"),
        hook_entry(point="session_start",tools=["write"]),hook_entry(permissionDecision="allow"),
        hook_entry(environment_env=Dict("SHENSCOPE_ROOT"=>"KEY")),hook_entry(allow_context=true,point="session_end")]
    for entry in invalid; @test_throws ShenScopeError hook_config(hook_test_config([entry])); end
    @test_throws ShenScopeError hook_config(hook_test_config([hook_entry(),hook_entry()]))
    @test_throws ShenScopeError hook_config(hook_test_config(;user_files=["relative/hooks.toml"]))
    @test_throws ShenScopeError hook_config(hook_test_config(;project_files=["x","x"]))
    @test_throws ShenScopeError hook_config(hook_test_config(;max_history=true))
    spec=ShenScope.hook_spec(hook_entry(environment_env=Dict("BOUND_KEY"=>"USER_KEY")))
    @test spec.name == "guard"
    @test spec.environment_env["BOUND_KEY"] == "USER_KEY"
    @test_throws ShenScopeError ShenScope.hook_parse_output("{\"decision\":\"allow\"}",spec,String[])
    @test_throws ShenScopeError ShenScope.hook_parse_output("{\"permissionDecision\":\"allow\"}",spec,String[])
    @test_throws ShenScopeError ShenScope.hook_parse_output("{\"decision\":\"deny\",\"decision\":\"continue\"}",spec,String[])
    @test_throws ShenScopeError ShenScope.hook_parse_output("{\"context\":\"implicit\"}",spec,String[])
    @test_throws ShenScopeError ShenScope.hook_parse_output("{\"context\":{\"nested\":{\"a\":{\"b\":{\"c\":{}}}}}}",spec,String[])
    @test ShenScope.hook_parse_output("{\"decision\":\"deny\",\"reason\":\"review required\"}",spec,String[]) == (:deny,"review required","")
end

@testset "Hook source identity, read scope, ambiguity and explicit reload" begin
    mktempdir() do root
      mktempdir() do user
        project=hook_file(root,[hook_entry()]);userpath=hook_file(user,[hook_entry()])
        config=hook_test_config(;project_files=["hooks.toml"],user_files=[userpath])
        ctx=model_context(root);manager=HookManager(config)
        snapshot=hooks_list(manager,ctx)
        @test length(snapshot["hooks"]) == 2
        @test Set(item["scope"] for item in snapshot["hooks"]) == Set(["project","user"])
        @test_throws ShenScopeError ShenScope.hook_find(manager.catalogs[root],"guard")
        selected=snapshot["hooks"][1]["id"]
        @test hooks_read_configuration(manager,selected,ctx)["path"] == project
        manager.config=hook_config(hook_test_config(;project_files=["hooks.toml"],user_files=[userpath],disabled=[selected]))
        @test_throws ShenScopeError hooks_list(manager,ctx)
        reloaded=hooks_list(manager,ctx;reload=true)
        @test reloaded["generation"] == 2
        @test !reloaded["hooks"][1]["enabled"]
        @test reloaded["hooks"][2]["enabled"]
        denied=RuntimeContext(root;permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
        @test_throws ShenScopeError hooks_list(manager,denied)
        write(project,read(project,String)*"\n# changed\n")
        @test_throws ShenScopeError hooks_read_configuration(manager,selected,ctx)
        symlink(project,joinpath(root,"linked.toml"))
        @test_throws ShenScopeError hooks_list(HookManager(hook_test_config(;project_files=["linked.toml"])),ctx)
        @test_throws ShenScopeError hooks_list(HookManager(hook_test_config(;project_files=[userpath])),ctx)
        hook_file(root,[hook_entry(name="secret")];name=".env.hooks")
        @test_throws ShenScopeError hooks_list(HookManager(hook_test_config(;project_files=[".env.hooks"])),ctx)
        hook_file(root,[hook_entry(),hook_entry()];name="duplicate.toml")
        @test_throws ShenScopeError hooks_list(HookManager(hook_test_config(;project_files=["duplicate.toml"])),ctx)
      end
    end
end
