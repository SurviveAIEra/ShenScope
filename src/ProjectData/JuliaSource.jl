function julia_byte_range(source::SourceMap, first::Int, after::Int)
    1 <= first <= after <= ncodeunits(source.source) + 1 ||
        throw(ShenScopeError(:source_position, "Julia parser emitted an invalid byte range"))
    isvalid(source.source, first) || first == ncodeunits(source.source) + 1 ||
        throw(ShenScopeError(:source_position, "Julia parser range splits a character"))
    isvalid(source.source, after) || after == ncodeunits(source.source) + 1 ||
        throw(ShenScopeError(:source_position, "Julia parser range splits a character"))
    line = searchsortedlast(source.starts, first)
    ending = searchsortedlast(source.starts, after)
    SourceRange(source.path, line, ending; start_column=first - source.starts[line] + 1,
        end_column=after - source.starts[ending] + 1)
end

julia_node_range(extraction::JuliaSyntaxExtraction, node) =
    julia_byte_range(extraction.source, JuliaSyntax.first_byte(node), JuliaSyntax.last_byte(node) + 1)

function julia_parse_diagnostics(source::SourceMap, error::JuliaSyntax.ParseError)
    result = Dict{String,Any}[]
    for diagnostic in error.diagnostics
        length(result) < 256 || break
        first = clamp(diagnostic.first_byte, 1, ncodeunits(source.source) + 1)
        after = clamp(diagnostic.last_byte + 1, first, ncodeunits(source.source) + 1)
        while first > 1 && !isvalid(source.source, first); first -= 1; end
        while after <= ncodeunits(source.source) && !isvalid(source.source, after); after += 1; end
        push!(result, Dict("category" => String(diagnostic.level), "message" => diagnostic.message,
            "location" => range_dict(julia_byte_range(source, first, after)), "source" => "JuliaSyntax",
            "semantic" => false, "incomplete_tag" => String(error.incomplete_tag)))
    end
    result
end

function julia_lexical_preflight(extraction::JuliaSyntaxExtraction)
    source = extraction.source.source
    ncodeunits(source) <= JULIA_SYNTAX_MAX_SOURCE ||
        throw(ShenScopeError(:graph, "Julia source exceeds the parser's 2 MiB limit"))
    # JuliaSyntax.tokenize invokes the parser. Use the pinned dependency's
    # streaming raw lexer so this guard really precedes recursive parsing.
    tokens = JuliaSyntax.Tokenize.tokenize(source)
    delimiters = 0; blocks = 0
    for (index, token) in enumerate(tokens)
        index <= JULIA_SYNTAX_MAX_NODES || throw(ShenScopeError(:graph, "Julia token count exceeds capacity"))
        index % 256 == 0 && julia_syntax_checkpoint!(extraction, 0)
        kind = julia_node_kind(token)
        if kind in ("(", "[", "{")
            delimiters += 1
        elseif kind in (")", "]", "}")
            delimiters = max(0, delimiters - 1)
        elseif kind in ("for", "if") && delimiters > 0
            # Comprehensions and generator filters have no matching `end`.
            continue
        elseif kind in ("begin", "quote", "function", "macro", "module", "baremodule", "struct", "let", "try", "while", "if", "for", "do", "abstract", "primitive")
            blocks += 1
        elseif kind == "end"
            blocks = max(0, blocks - 1)
        end
        max(delimiters, blocks) <= JULIA_SYNTAX_MAX_PARSE_NESTING ||
            throw(ShenScopeError(:graph, "Julia lexical nesting exceeds parser capacity"))
    end
    nothing
end

function julia_parse_source(extraction::JuliaSyntaxExtraction)
    source = extraction.source
    check_cancelled(extraction.context.cancellation)
    julia_lexical_preflight(extraction)
    # No eval, macro expansion, include or package loading is performed.
    try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source.source; filename=source.path,
            ignore_warnings=true)
    catch error
        error isa StackOverflowError && throw(ShenScopeError(:graph, "Julia expression nesting exceeds parser stack capacity"))
        error isa JuliaSyntax.ParseError || rethrow()
        append!(extraction.diagnostics, julia_parse_diagnostics(source, error))
        nothing
    end
end

function julia_name_node(node)
    kind = julia_node_kind(node)
    children = julia_node_children(node)
    kind in ("Identifier", "MacroName", "Operator") && return node
    kind in ("curly", "where", "::", "<:", "...", "quote", "parens") &&
        !isempty(children) && return julia_name_node(first(children))
    if kind == "." && !isempty(children)
        return julia_name_node(last(children))
    end
    isempty(children) ? node : nothing
end

function julia_dotted_name(node)
    kind = julia_node_kind(node); children = julia_node_children(node)
    if kind == "." && length(children) == 2
        left = julia_dotted_name(children[1]); right = julia_dotted_name(children[2])
        return left === nothing || right === nothing ? nothing : left * "." * right
    elseif kind in ("quote", "curly", "parens") && !isempty(children)
        return julia_dotted_name(first(children))
    elseif isempty(children)
        kind in ("Identifier", "MacroName") || JuliaSyntax.is_operator(JuliaSyntax.kind(node)) || return nothing
        return julia_syntax_text(node)
    end
    nothing
end

function julia_literal_string(node)
    julia_node_kind(node) == "string" || return nothing
    children = julia_node_children(node)
    all(child -> julia_node_kind(child) == "String", children) || return nothing
    value = try
        Expr(node)
    catch
        return nothing
    end
    value isa String ? value : nothing
end
