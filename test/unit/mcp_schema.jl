@testset "MCP bounded schema assertions and references" begin
    validate(value, schema) = validate_mcp_schema(value, schema)
    @test validate(1.0, Dict("type" => "integer")) == 1
    @test_throws ShenScopeError validate(true, Dict("type" => "integer"))
    @test validate(nothing, Dict("type" => ["string", "null"])) === nothing
    @test_throws ShenScopeError validate(1, Dict("type" => ["string", "null"]))
    @test validate(1, Dict("enum" => [1.0, "x"])) == 1
    @test_throws ShenScopeError validate(true, Dict("enum" => [1]))
    @test validate("中文", Dict("type" => "string", "minLength" => 2, "maxLength" => 2, "pattern" => "^中文\$")) == "中文"
    @test_throws ShenScopeError validate("文", Dict("minLength" => 2))
    @test_throws ShenScopeError validate("abc", Dict("pattern" => "["))
    @test validate(1.2, Dict("type" => "number", "multipleOf" => 0.1, "exclusiveMinimum" => 1, "exclusiveMaximum" => 2)) == 1.2
    @test_throws ShenScopeError validate(1.25, Dict("multipleOf" => 0.1))
    @test_throws ShenScopeError validate(2, Dict("exclusiveMaximum" => 2))
    @test validate([1, "a"], Dict("prefixItems" => [Dict("type" => "integer"), Dict("type" => "string")], "items" => false)) == [1, "a"]
    @test_throws ShenScopeError validate([1, "a", 2], Dict("prefixItems" => [true, true], "items" => false))
    @test_throws ShenScopeError validate([1, 1.0], Dict("uniqueItems" => true))
    @test validate([1, "a"], Dict("contains" => Dict("type" => "string"), "minContains" => 1, "maxContains" => 1)) == [1, "a"]
    @test_throws ShenScopeError validate(["a", "b"], Dict("contains" => Dict("type" => "string"), "maxContains" => 1))
    object = Dict("type" => "object", "properties" => Dict("a" => Dict("type" => "integer")),
        "patternProperties" => Dict("^x" => Dict("type" => "string")), "additionalProperties" => false,
        "dependentRequired" => Dict("a" => ["x1"]), "propertyNames" => Dict("maxLength" => 3))
    @test validate(Dict("a" => 1, "x1" => "yes"), object)["a"] == 1
    @test_throws ShenScopeError validate(Dict("a" => 1), object)
    @test_throws ShenScopeError validate(Dict("b" => 1), object)
    @test_throws ShenScopeError validate(Dict("xxxx" => "yes"), object)
    @test_throws ShenScopeError validate(Dict("a" => 1), Dict("dependentSchemas" => Dict("a" => Dict("required" => ["b"]))))
    @test validate(2, Dict("allOf" => [Dict("minimum" => 1), Dict("maximum" => 3)])) == 2
    @test_throws ShenScopeError validate(4, Dict("allOf" => [Dict("minimum" => 1), Dict("maximum" => 3)]))
    @test validate(1, Dict("oneOf" => [Dict("type" => "number"), Dict("type" => "string")])) == 1
    @test_throws ShenScopeError validate(1, Dict("oneOf" => [Dict("type" => "number"), Dict("type" => "integer")]))
    @test_throws ShenScopeError validate("bad", Dict("not" => Dict("const" => "bad")))
    conditional = Dict("if" => Dict("type" => "number"), "then" => Dict("minimum" => 5), "else" => Dict("type" => "string"))
    @test validate(6, conditional) == 6
    @test validate("a", conditional) == "a"
    @test_throws ShenScopeError validate(3, conditional)
    recursive = Dict("\$defs" => Dict("node" => Dict("type" => "object", "properties" => Dict("next" => Dict("\$ref" => "#/\$defs/node")))), "\$ref" => "#/\$defs/node")
    @test validate(Dict("next" => Dict()), recursive) == Dict("next" => Dict())
    @test_throws ShenScopeError validate(Dict("next" => "bad"), recursive)
    @test_throws ShenScopeError validate(Dict(), Dict("\$ref" => "#"))
    @test_throws ShenScopeError validate(1, Dict("\$ref" => "https://example.invalid/schema"))
    @test_throws ShenScopeError validate(1, Dict("\$ref" => "#/missing"))
    @test_throws ShenScopeError validate(Dict(), Dict("unevaluatedProperties" => false))
    @test_throws ShenScopeError validate("x", Dict("required" => ["a", "a"]))
    @test_throws ShenScopeError validate("x", Dict("minimum" => NaN))
    @test_throws ShenScopeError validate("x", Dict("properties" => 1))
    @test_throws ShenScopeError validate([1], Dict("items" => [true], "prefixItems" => [true]))
end

@testset "MCP framing, content and configuration bounds" begin
    responses = Any[]
    line = canonical(Dict("jsonrpc" => "2.0", "id" => "中文", "result" => Dict("text" => "中文"))) * "\r\n"
    decoder = ShenScope.MCPLineDecoder()
    for byte in codeunits(line); ShenScope.feed_mcp_lines!(item -> push!(responses, item), decoder, [byte]); end
    @test responses[1]["result"]["text"] == "中文"
    @test_throws ShenScopeError ShenScope.feed_mcp_lines!(identity, ShenScope.MCPLineDecoder(8), collect(codeunits("123456789")))
    @test_throws ShenScopeError ShenScope.mcp_decode("not JSON")
    @test_throws ShenScopeError ShenScope.mcp_decode("{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}")
    @test_throws ShenScopeError ShenScope.mcp_decode("{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":{}}")
    @test_throws ShenScopeError ShenScope.mcp_decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}")
    @test_throws ShenScopeError ShenScope.mcp_decode(repeat("[", 65))
    sse = ShenScope.MCPSSEDecoder()
    events = Any[]; ids = String[]
    wire = "id: priming\n\nid: answer\ndata: " * canonical(Dict("jsonrpc" => "2.0", "id" => 1, "result" => Dict("text" => "分片"))) * "\n\n"
    for byte in codeunits(wire); ShenScope.feed_mcp_sse!(item -> push!(events, item), id -> push!(ids, id), sse, [byte]); end
    @test ids == ["priming", "answer"]
    @test events[1]["result"]["text"] == "分片"
    @test_throws ShenScopeError ShenScope.feed_mcp_sse!(identity, identity, ShenScope.MCPSSEDecoder(8), collect(codeunits("data: 123456789")))
    @test ShenScope.mcp_base64("YQ==") == "YQ=="
    @test ShenScope.mcp_base64("") == ""
    @test_throws ShenScopeError ShenScope.mcp_base64("=abc")
    @test_throws ShenScopeError ShenScope.mcp_base64("éaaa")
    @test ShenScope.mcp_content(Dict("type" => "image", "data" => "YQ==", "mimeType" => "image/png"))["data"] == "YQ=="
    @test ShenScope.mcp_content(Dict("type" => "resource_link", "uri" => "fixture://x", "name" => "x"))["uri"] == "fixture://x"
    @test_throws ShenScopeError ShenScope.mcp_content(Dict("type" => "video", "data" => "YQ=="))
    @test_throws ShenScopeError ShenScope.mcp_resource_content(Dict("uri" => "fixture://x", "text" => "a", "blob" => "YQ=="))
    @test_throws ShenScopeError MCPServerSpec("x", Dict("argv" => ["python3"], "env" => Dict("key" => "raw")))
    @test_throws ShenScopeError MCPServerSpec("x", Dict("transport" => "http", "endpoint" => "https://user:key@example.invalid/mcp"))
    @test_throws ShenScopeError MCPServerSpec("x", Dict("transport" => "http", "endpoint" => "https://example.invalid/mcp", "header_env" => [Dict("name" => "Mcp-Session-Id", "env" => "KEY")]))
    @test_throws ShenScopeError MCPServerSpec("x", Dict("argv" => ["python3"], "timeout" => Inf))
    @test length(mcp_tool_alias("x", repeat("tool/", 100))) <= 64
    @test mcp_tool_alias("a/b", "c") != mcp_tool_alias("a_b", "c")
    @test mcp_tool_alias("a", "b_c") != mcp_tool_alias("a_b", "c")
end
