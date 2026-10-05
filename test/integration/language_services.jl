function real_language_context(root)
    RuntimeContext(root;session_id="real-lsp",state_dir=joinpath(root,"state"),
        permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Allow,:edit=>Allow)))
end

const LANGUAGE_SERVER_HOME=get(ENV,"SHENSCOPE_LANGUAGE_SERVERS","/workspace/tool-cache/language-servers/node_modules")

@testset "Real Pyright checks Python, navigates source and replaces versioned reports" begin
    mktempdir() do root
        write(joinpath(root,"sample.py"),"value: int = \"wrong\"\ndef add(a: int, b: int) -> int:\n    return a + b\nanswer = add(1, 2)\n")
        ctx=real_language_context(root);manager=LanguageServiceManager();problems=ProblemManager()
        executable=joinpath(LANGUAGE_SERVER_HOME,".bin","pyright-langserver")
        spec=language_server_spec(Dict("name"=>"python","argv"=>[executable,"--stdio"],"languages"=>["python"],
            "settings"=>Dict("python"=>Dict("analysis"=>Dict("typeCheckingMode"=>"strict"))),"timeout"=>30))
        try
            status=start_language_service!(manager,spec,ctx)
            @test status["state"]=="ready" && !status["server_process_os_isolated"]
            client=ShenScope.owned_language_client(manager,"python",ctx)
            @test synchronize_language_document!(client,"sample.py",ctx)["version"]==1
            diagnostics=wait_language_diagnostics(client,"sample.py",ctx;timeout=20)
            @test diagnostics["diagnostic_version_verified"] && diagnostics["retained_diagnostics"]>=1
            first=capture_language_problems!(problems,client,ctx)
            @test project_problem_editor_snapshot(problems,first.id,ctx)["markers"]>=1
            hover=query_language_server(client,"hover",Dict("path"=>"sample.py","line"=>3,"character"=>10),ctx)
            @test hover["available"] && !isempty(hover["contents"])
            definitions=query_language_server(client,"definitions",Dict("path"=>"sample.py","line"=>3,"character"=>10),ctx)
            @test any(item->item["path"]=="sample.py" && item["location"]["start_line"]==2,definitions["items"])
            symbols=query_language_server(client,"document_symbols",Dict("path"=>"sample.py"),ctx)
            @test any(item->item["name"]=="add",symbols["items"])
            completions=query_language_server(client,"completions",Dict("path"=>"sample.py","line"=>3,"character"=>0),ctx)
            @test !completions["automatic_insertion"] && !isempty(completions["items"])
            signatures=query_language_server(client,"signature_help",Dict("path"=>"sample.py","line"=>3,"character"=>14),ctx)
            @test signatures["available"] && any(item->occursin("a:",item["label"]),signatures["signatures"])
            calls=query_language_call_hierarchy(client,"incoming_calls",Dict("path"=>"sample.py","line"=>1,"character"=>5),ctx)
            @test any(item->item["name"]=="add",calls["roots"])
            @test !isempty(calls["calls"]) && !calls["runtime_calls_independently_verified"]
            write(joinpath(root,"sample.py"),"value: int = 42\ndef add(a: int, b: int) -> int:\n    return a + b\nanswer = add(1, 2)\n")
            @test project_problem_editor_snapshot(problems,first.id,ctx)["markers"]==0
            @test synchronize_language_document!(client,"sample.py",ctx)["version"]==2
            @test wait_language_diagnostics(client,"sample.py",ctx;timeout=20)["diagnostic_version_verified"]
            current=capture_language_problems!(problems,client,ctx)
            @test project_problem_editor_snapshot(problems,current.id,ctx)["markers"]==0
            foreign=RuntimeContext(root;session_id="foreign",state_dir=ctx.state_dir)
            @test_throws ShenScopeError ShenScope.owned_language_client(manager,"python",foreign)
            @test_throws ShenScopeError start_language_service!(manager,spec,ctx)
            ctx.permissions.rules[:process]=Deny
            @test timedwait(()->client.state==:failed,5)==:ok
            @test_throws ShenScopeError query_language_server(client,"hover",Dict("path"=>"sample.py"),ctx)
        finally
            close_language_services!(manager)
        end
    end
end

@testset "Real TypeScript LSP returns verified references and nonexecuting rename edits" begin
    mktempdir() do root
        write(joinpath(root,"sample.ts"),"export function add(a: number,b: number) { return a+b; }\nconst value: number = \"wrong\";\nadd(1,2);\n")
        ctx=real_language_context(root);manager=LanguageServiceManager()
        spec=language_server_spec(Dict("name"=>"typescript","argv"=>[joinpath(LANGUAGE_SERVER_HOME,".bin","typescript-language-server"),"--stdio"],
            "languages"=>["typescript","javascript"],"initialization_options"=>Dict("tsserver"=>Dict("path"=>joinpath(LANGUAGE_SERVER_HOME,"typescript","lib","tsserver.js"))),"timeout"=>30))
        try
            @test start_language_service!(manager,spec,ctx)["state"]=="ready"
            client=ShenScope.owned_language_client(manager,"typescript",ctx)
            synchronize_language_document!(client,"sample.ts",ctx)
            refs=query_language_server(client,"references",Dict("path"=>"sample.ts","line"=>2,"character"=>1),ctx)
            @test length(refs["items"])>=2 && refs["source_versions_verified"]
            rename=query_language_server(client,"rename",Dict("path"=>"sample.ts","line"=>2,"character"=>1,"new_name"=>"sum"),ctx)
            @test length(only(rename["files"])["edits"])>=2 && rename["requires_explicit_apply"]
            @test occursin("function add",read(joinpath(root,"sample.ts"),String))
            @test close_language_document!(client,"sample.ts",ctx)["closed"]
            @test !close_language_document!(client,"sample.ts",ctx)["closed"]
            @test stop_language_service!(manager,"typescript",ctx)["stopped"]
            @test isempty(list_language_services(manager,ctx)["servers"])
        finally
            close_language_services!(manager)
        end
    end
end
