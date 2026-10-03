@testset "Compiler UTF-16 positions normalize to validated UTF-8 source ranges" begin
    source = ShenScope.SourceMap("u.ts", "中😀x\r\n한국어\nlast\u2028\u2029")
    @test length(source.starts) == 5
    @test ShenScope.utf16_byte_column(source, 1, 0) == 1
    @test ShenScope.utf16_byte_column(source, 1, 1) == 4
    @test ShenScope.utf16_byte_column(source, 1, 3) == 8
    @test ShenScope.utf16_byte_column(source, 1, 4) == 9
    @test_throws ShenScopeError ShenScope.utf16_byte_column(source, 1, 2)
    @test_throws ShenScopeError ShenScope.source_byte_index(source, 1, 2)
    @test_throws ShenScopeError ShenScope.source_byte_index(source, 1, 10)
    @test_throws ShenScopeError ShenScope.source_byte_index(source, 0, 1)
    @test_throws ShenScopeError ShenScope.source_byte_index(source, true, 1)
    @test_throws ShenScopeError ShenScope.utf16_byte_column(source, 1, false)
    range = ShenScope.compiler_range(source, Dict("start" => Dict("line" => 0, "character" => 1),
        "end" => Dict("line" => 0, "character" => 3)))
    @test range.start_column == 4 && range.end_column == 8
    @test ShenScope.source_range_text(source, range) == "😀"
    @test ShenScope.range_utf16(source, range) == Dict("start" => Dict("line" => 0, "character" => 1),
        "end" => Dict("line" => 0, "character" => 3))
    @test_throws ShenScopeError ShenScope.compiler_range(source, Dict("start" => Dict("line" => 0, "character" => 3),
        "end" => Dict("line" => 0, "character" => 1)))
    @test_throws ShenScopeError ShenScope.compiler_position(source, Dict("line" => 99, "character" => 0))
    @test_throws ShenScopeError ShenScope.compiler_position(source, Dict("line" => 0.0, "character" => 0))
    @test_throws ShenScopeError SourceRange("u.ts", 1, 1; start_column=8, end_column=4)
    for text in ("", "ASCII", "中文😀한글", repeat("a中😀", 2000))
        map = ShenScope.SourceMap("roundtrip.ts", text)
        for index in unique(vcat(collect(eachindex(text)), ncodeunits(text)+1))
            prefix = index == 1 ? "" : String(SubString(text, 1, prevind(text, index)))
            expected = length(transcode(UInt16, prefix))
            @test ShenScope.byte_utf16_character(map, 1, index) == expected
            @test ShenScope.utf16_byte_column(map, 1, expected) == index
        end
        @test length(map.checkpoints) <= 1
    end
end

@testset "Compiler JSONC preserves literals and rejects ambiguous or excessive data" begin
    value = ShenScope.compiler_jsonc("\ufeff{/* block */\"url\":\"https://example.test/*literal*/\",// line\r\n\"values\":[1,2,],}")
    @test value["url"] == "https://example.test/*literal*/"
    @test value["values"] == [1,2]
    @test ShenScope.compiler_jsonc("{\"escaped\":\"\\\"//keep\", \"object\":{\"v\":true,},}")["escaped"] == "\"//keep"
    for text in ("{/* open", "{\"x\":\"open}", "[]", "{}{}", "{\"x\":1,\"x\":2}",
            "{\"x\":1,\"\\u0078\":2}", "{,}", "{\"a\":NaN}", "{\"x\":"*repeat("[",32)*"0"*repeat("]",32)*"}")
        @test_throws ShenScopeError ShenScope.compiler_jsonc(text)
    end
    @test_throws ShenScopeError ShenScope.compiler_jsonc("{\"x\":\"12345\"}"; maximum=4)
end
