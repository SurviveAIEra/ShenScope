@testset "LSP framing handles every split, UTF-8 lengths and malformed boundaries" begin
    values=[Dict("jsonrpc"=>"2.0","id"=>"1","method"=>"hover","params"=>Dict("text"=>"中😀")),
        Dict("jsonrpc"=>"2.0","id"=>"1","result"=>nothing)]
    bytes=collect(codeunits(join(ShenScope.language_encoded_frame.(values))))
    for split_at in 0:length(bytes)
        decoded=Any[];decoder=ShenScope.LanguageFrameDecoder()
        ShenScope.feed_language_frames!(x->push!(decoded,x),decoder,bytes[1:split_at])
        ShenScope.feed_language_frames!(x->push!(decoded,x),decoder,bytes[split_at+1:end])
        @test decoded==values
        @test ShenScope.finish_language_frames!(identity,decoder)===nothing
    end
    for header in ("Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "Content-Length: -1\r\n\r\n", "Content-Length: 999999999\r\n\r\n",
            "Content-Type: application/json; charset=utf-16\r\nContent-Length: 2\r\n\r\n{}")
        @test_throws ShenScopeError ShenScope.feed_language_frames!(identity,ShenScope.LanguageFrameDecoder(),collect(codeunits(header)))
    end
    partial=ShenScope.LanguageFrameDecoder()
    ShenScope.feed_language_frames!(identity,partial,collect(codeunits("Content-Length: 20\r\n\r\n{}")))
    @test_throws ShenScopeError ShenScope.finish_language_frames!(identity,partial)
    @test_throws ShenScopeError ShenScope.feed_language_frames!(identity,ShenScope.LanguageFrameDecoder(;maximum_header=128),fill(UInt8('a'),129))
end

@testset "LSP contracts distinguish UTF-16 text lines, protected URIs and edit proposals" begin
    mktempdir() do root
        write(joinpath(root,"中.ts"),"中😀\u2028value\r\n")
        ctx=model_context(root)
        source=read_workspace_snapshot(ctx,"中.ts";unicode_line_separators=false)
        @test length(source.source.starts)==2
        @test source_editor_range(source.source,SourceRange("中.ts",1,1;start_column=11,end_column=16))["start"]["character"]==4
        uri=ShenScope.mcp_file_uri(source.absolute)
        @test ShenScope.language_workspace_uri(ctx,uri)[2]=="中.ts"
        @test_throws ShenScopeError ShenScope.language_workspace_uri(ctx,"file:///tmp/outside.py")
        @test_throws ShenScopeError ShenScope.language_workspace_uri(ctx,"https://example.test/x")
        @test_throws ShenScopeError ShenScope.language_workspace_uri(ctx,uri*"?query=1")
        @test_throws ShenScopeError ShenScope.language_workspace_uri(ctx,"file://"*root*"/%ZZ")
        @test_throws ShenScopeError ShenScope.language_server_capabilities(Dict("capabilities"=>Dict("positionEncoding"=>"utf-8")))
        caps=ShenScope.language_server_capabilities(Dict("capabilities"=>Dict("textDocumentSync"=>2,"hoverProvider"=>true)))
        @test caps["sync_kind"]==2 && caps["hover"] && !caps["rename"]
        spec=language_server_spec(Dict("name"=>"fixture","argv"=>["python3","-u"],"languages"=>["typescript"]))
        client=LanguageClient(spec,ctx)
        edit=Dict("changes"=>Dict(uri=>[Dict("range"=>Dict("start"=>Dict("line"=>0,"character"=>4),"end"=>Dict("line"=>0,"character"=>9)),"newText"=>"name")]))
        normalized=ShenScope.language_workspace_edit(edit,client,ctx)
        @test only(normalized["files"])["expected_sha256"]==source.sha256 && normalized["requires_explicit_apply"]
        @test read(source.absolute,String)==source.source.source
        @test_throws ShenScopeError ShenScope.language_workspace_edit(Dict("documentChanges"=>[Dict("kind"=>"delete","uri"=>uri)]),client,ctx)
        @test_throws ShenScopeError ShenScope.language_workspace_edit(Dict("documentChanges"=>[Dict("textDocument"=>Dict("uri"=>uri,"version"=>3),"edits"=>Any[])]),client,ctx)
        literal=ShenScope.normalize_language_hover(Dict("contents"=>Dict("kind"=>"plaintext","value"=>"<script>not HTML</script>")),source)
        @test only(literal["contents"])["kind"]=="plaintext" && literal["content_is_untrusted_server_text"]
    end
end
