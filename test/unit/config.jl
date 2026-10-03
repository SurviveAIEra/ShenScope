@testset "Configuration profiles, credential rejection and CAS" begin
    mktempdir() do root
        path=joinpath(root,"config.toml")
        config=load_config(;path)
        revision=save_config!(config;path,expected_sha256=digest(""))
        @test digest(read(path,String))==revision
        @test load_config(;path)==config
        @test_throws ShenScopeError save_config!(config;path,expected_sha256="stale")
        config["provider"]["api_key"]="fixture-not-a-real-key"
        @test_throws ShenScopeError save_config!(config;path)
        delete!(config["provider"],"api_key")
        config["budget"]["max_steps"]=0
        @test_throws ArgumentError save_config!(config;path)
        config["budget"]["max_steps"]=100
        config["provider"]["timeout"]=Inf
        @test_throws ShenScopeError save_config!(config;path)
        config["provider"]["timeout"]=120.0
        config["budget"]["max_seconds"]=Inf
        @test_throws ArgumentError save_config!(config;path)
        @test digest(read(path,String))==revision
        write(path,"[profiles.local.provider]\nprotocol = 'ollama'\nendpoint = 'http://127.0.0.1:11434'\nmodel = 'fixture'\n")
        localconfig=load_config(;path,profile="local")
        @test localconfig["provider"]["protocol"]=="ollama"
        @test_throws ShenScopeError load_config(;path,profile="missing")
    end
end

@testset "Canonical numeric journal round trips" begin
    mktempdir() do root
        j=Journal(joinpath(root,"numbers.jsonl"))
        value=Dict("zero"=>0.0,"negative_zero"=>-0.0,"whole"=>10.0,"fraction"=>1.25,
            "nested"=>[Dict("cost"=>0.0)])
        append_record!(j,value)
        @test journal_records(j)==[value]
        @test canonical(value)==canonical(parsejson(canonical(value)))
        @test_throws ShenScopeError canonical(NaN)
    end
end
