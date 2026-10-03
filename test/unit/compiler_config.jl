@testset "Compiler configuration inheritance, source scope and post-read integrity" begin
    mktempdir() do root
        mkpath(joinpath(root,"src"));mkpath(joinpath(root,"config"))
        write(joinpath(root,"src","文件.ts"),"export const 值 = 1;\n")
        write(joinpath(root,"other.ts"),"export const other = 2;\n")
        write(joinpath(root,"config","base.json"),"{\"compilerOptions\":{\"strict\":false,\"baseUrl\":\"..\",\"paths\":{\"@/*\":[\"src/*\"]}},\"include\":[\"../src/**/*.ts\"]}")
        write(joinpath(root,"tsconfig.json"),"{// override\n\"extends\":\"./config/base.json\",\"compilerOptions\":{\"strict\":true},}")
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=r->:once)
        config=ShenScope.load_compiler_config(ctx)
        @test config.options["strict"]===true
        @test config.options["noEmit"]===true
        @test config.options["paths"]["@/*"]==[joinpath(root,"src","*")]
        @test ShenScope.compiler_project_paths(ctx,config)==["src/文件.ts"]
        @test length(config.sources)==2
        @test ShenScope.verify_compiler_config(config,ctx)===nothing
        write(joinpath(root,"config","base.json"),"{\"compilerOptions\":{\"strict\":true}}")
        @test_throws ShenScopeError ShenScope.verify_compiler_config(config,ctx)
        write(joinpath(root,"tsconfig.json"),"{\"extends\":\"./tsconfig.json\"}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{\"compilerOptions\":{\"plugins\":[{\"name\":\"untrusted\"}]}}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{\"extends\":\"../outside.json\"}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{\"compilerOptions\":{\"paths\":{\"@/*\":[\"../escape/*\"]}}}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{\"files\":[\"other.ts\"],\"exclude\":[\"**\"]}")
        @test ShenScope.compiler_project_paths(ctx,ShenScope.load_compiler_config(ctx))==["other.ts"]
        write(joinpath(root,"tsconfig.json"),"{\"compilerOptions\":{\"types\":[\"node\"]}}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{\"references\":[{\"path\":\"./src\"}]}")
        @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        rm(joinpath(root,"tsconfig.json"))
        absent=ShenScope.load_compiler_config(ctx)
        write(joinpath(root,"tsconfig.json"),"{}")
        @test_throws ShenScopeError ShenScope.verify_compiler_config(absent,ctx)
        deny=RuntimeContext(root;state_dir=joinpath(root,"denied"),
            permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
        @test_throws ShenScopeError ShenScope.load_compiler_config(deny)
        if !Sys.iswindows()
            rm(joinpath(root,"tsconfig.json"));symlink(joinpath(root,"config","base.json"),joinpath(root,"tsconfig.json"))
            @test_throws ShenScopeError ShenScope.load_compiler_config(ctx)
        end
    end
end

@testset "Compiler globs have bounded segment and recursive semantics" begin
    @test ShenScope.compiler_glob_match("src/**/*.ts","src/file.ts")
    @test ShenScope.compiler_glob_match("src/**/*.ts","src/a/b/中文.ts")
    @test !ShenScope.compiler_glob_match("src/*.ts","src/a/file.ts")
    @test ShenScope.compiler_glob_match("**/test?.ts","test1.ts")
    @test !ShenScope.compiler_glob_match("**/test?.ts","tests12.ts")
    @test ShenScope.compiler_glob_match("**","a/b/c.ts")
end
