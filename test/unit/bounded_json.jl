@testset "Bounded JSON encoding matches canonical wire data and rejects before unbounded traversal" begin
    values = Any[nothing,true,false,0,-0.0,1.5,typemax(Int64),"中文😀\u2028",[1,true,nothing],Dict("z"=>2,"a"=>"quoted \" value")]
    append!(values,[string(Char(code)) for code in 0:31])
    for value in values
        encoded = bounded_canonical_json(value;maximum=4096)
        @test encoded == canonical(value)
        @test canonical(parsejson(encoded)) == encoded
    end
    @test bounded_canonical_json(Dict("value"=>"中😀\n")) == canonical(Dict("value"=>"中😀\n"))
    @test_throws ShenScopeError bounded_canonical_json("\u0000";maximum=7)
    @test_throws ShenScopeError bounded_canonical_json(repeat("x",1024);maximum=16)
    @test_throws ShenScopeError bounded_canonical_json(String(UInt8[0xff]))
    @test_throws ShenScopeError bounded_canonical_json(Dict(:symbol=>1))
    @test_throws ShenScopeError bounded_canonical_json(Inf)
    @test_throws ShenScopeError bounded_canonical_json(1//3)
    @test_throws ShenScopeError bounded_canonical_json(collect(1:10);max_nodes=10)
    @test bounded_canonical_json(collect(1:10);max_nodes=11) == canonical(collect(1:10))
    @test_throws ShenScopeError bounded_canonical_json(Dict(string(i)=>i for i in 1:10);max_nodes=20)
    cycle = Dict{String,Any}();cycle["self"] = cycle
    @test_throws ShenScopeError bounded_canonical_json(cycle;max_depth=4)
    @test_throws ArgumentError bounded_canonical_json(Dict();maximum=true)
end
