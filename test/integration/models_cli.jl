function captured_models_cli(args,root)
    path = joinpath(root,"cli-output.txt")
    status = open(path,"w") do output
        redirect_stdout(output) do;ShenScope.main(args);end
    end
    raw = read(path,String)
    status, isempty(strip(raw)) ? nothing : parsejson(raw)
end

@testset "Model CLI uses bounded explicit input and honest stateless catalogs" begin
    mktempdir() do root
        calls = Ref(0)
        model_service_fixture(request->begin
            calls[] += 1
            HTTP.Response(200,["Content-Type"=>"application/json"],canonical(endswith(request.target,"/count_tokens") ?
                Dict("input_tokens"=>17) : Dict("data"=>[Dict("id"=>"first"),Dict("id"=>"second")])) )
        end) do endpoint
            config = joinpath(root,"config.toml")
            write(config,"[provider]\nprotocol='anthropic'\nendpoint='"*endpoint*"'\nmodel='active'\n[permissions]\nnetwork='ask'\n")
            common = ["--root",root,"--state-dir",joinpath(root,"state"),"--config",config]
            status,value = captured_models_cli(["models","status",common...],root)
            @test status == 0 && value["configured"]["id"] == "active"
            status,value = captured_models_cli(["models","health",common...],root)
            @test status == 0 && value["state"] == "closed" && !value["tracked"]
            @test value["revision"] == 0 && !value["network_probe_performed"] && calls[] == 0
            status,value = captured_models_cli(["models","refresh",common...,"--allow-network","--offset","1","--limit","1"],root)
            @test status == 0 && value["total"] == 2 && value["models"][1]["id"] == "second"
            @test length(value["models"]) == 1 && value["offset"] == 1
            status,value = captured_models_cli(["models","list",common...],root)
            @test status == 0 && value["total"] == 0 && value["lifetime"] == "conversation"
            write(joinpath(root,"request.json"),canonical(Dict("messages"=>[Dict("role"=>"user","text"=>"CLI 中文😀")],"max_output"=>32)))
            status,value = captured_models_cli(["models","count","request.json",common...,"--count-mode","estimate"],root)
            @test status == 0 && value["source"] == "estimate" && calls[] == 1
            status,value = captured_models_cli(["models","count","request.json",common...,"--count-mode","provider","--allow-network"],root)
            @test status == 0 && value["input_tokens"] == 17 && calls[] == 2
            for args in (["refresh","--limit","0"],["refresh","--offset","-1"],["count","../outside.json"],
                    ["count","request.json","--count-mode","invalid"],["inspect","unknown"])
                @test ShenScope.main(["models",args...,common...]) == 1
            end
            write(joinpath(root,"bad-request.json"),"{malformed")
            @test ShenScope.main(["models","count","bad-request.json",common...]) == 1
            @test calls[] == 2
        end
    end
end
