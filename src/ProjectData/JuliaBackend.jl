function julia_validate_tree!(extraction::JuliaSyntaxExtraction, tree)
    stack = [(tree, 0)]; count = 0
    while !isempty(stack)
        node, depth = pop!(stack)
        count += 1
        count <= JULIA_SYNTAX_MAX_NODES && depth <= JULIA_SYNTAX_MAX_DEPTH ||
            throw(ShenScopeError(:graph, "Julia syntax tree exceeds extraction limits"))
        if count % 256 == 0
            project_query_tick(extraction.context)
        end
        for child in julia_node_children(node); push!(stack, (child, depth + 1)); end
    end
    count
end

function julia_extract_document(document::AbstractDict, ctx::RuntimeContext)
    path = document["path"]; source = document["source"]
    document["language"] == "julia" && path isa String && source isa String &&
        digest(source) == document["sha256"] || throw(ShenScopeError(:graph, "Invalid Julia source snapshot"))
    workspace_path(ctx.root, path)
    ncodeunits(source) <= JULIA_SYNTAX_MAX_SOURCE ||
        throw(ShenScopeError(:graph, "Julia source exceeds the parser's 2 MiB limit"))
    extraction = JuliaSyntaxExtraction(SourceMap(path, source), ctx)
    file_id = symbol_id("julia_syntax", path, "file")
    file_range = julia_byte_range(extraction.source, 1, ncodeunits(source) + 1)
    push!(extraction.symbols, CodeSymbol(file_id, :file, basename(path), path, file_range,
        :julia, Dict{String,Any}("backend" => "julia_syntax", "semantic" => false)))
    tree = julia_parse_source(extraction)
    if tree !== nothing
        julia_validate_tree!(extraction, tree)
        julia_walk!(extraction, tree, JuliaSyntaxScope(file_id, "", "", :file), 0)
        julia_link_local_types!(extraction)
    end
    metadata = Dict{String,Any}("backend" => "julia_syntax", "parser_version" => string(Base.pkgversion(JuliaSyntax)),
        "semantic" => false, "compiler_confirmed" => false, "source_evaluated" => false,
        "parse_complete" => tree !== nothing, "julia_calls" => extraction.calls,
        "julia_imports" => extraction.imports, "julia_includes" => extraction.includes,
        "julia_exports" => extraction.exports, "visited_nodes" => extraction.visited,
        "limitations" => ["no_macro_expansion", "no_runtime_dispatch", "no_cross_file_binding_resolution",
            "no_generated_function_execution", "no_package_loading"])
    FileFacts(path, document["sha256"], extraction.symbols, extraction.relations, extraction.references,
        extraction.diagnostics, SymbolOccurrence[], metadata)
end

function extract_files(::JuliaSyntaxBackend, documents, ctx; all_documents=documents,
        deleted=String[], full=false)
    facts = FileFacts[]
    for document in documents
        check_cancelled(ctx.cancellation)
        project_query_tick(ctx)
        push!(facts, julia_extract_document(document, ctx))
    end
    facts
end
