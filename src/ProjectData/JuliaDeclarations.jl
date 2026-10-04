function julia_declaration!(extraction::JuliaSyntaxExtraction, scope::JuliaSyntaxScope,
        kind::Symbol, name::String, node; metadata=Dict{String,Any}(), identity=name,
        qualification=julia_qualified_name(scope, name))
    length(extraction.symbols) < JULIA_SYNTAX_MAX_SYMBOLS ||
        throw(ShenScopeError(:graph, "Julia declaration count exceeds capacity"))
    key = canonical([String(kind), qualification, identity])
    ordinal = get(extraction.ordinals, key, 0); extraction.ordinals[key] = ordinal + 1
    id = symbol_id("julia_syntax", extraction.source.path, key, ordinal)
    location = julia_node_range(extraction, node)
    details = merge(Dict{String,Any}("backend" => "julia_syntax", "semantic" => false,
        "compiler_confirmed" => false, "module" => scope.module_name, "syntax_ordinal" => ordinal), metadata)
    symbol = CodeSymbol(id, kind, name, qualification, location, :julia, details)
    push!(extraction.symbols, symbol); push!(extraction.declaration_ids, id)
    push!(extraction.relations, Relation(scope.owner, id, :contains, location; provenance="julia_syntax_declaration"))
    symbol
end

function julia_walk_module!(extraction, node, scope, depth)
    children = julia_node_children(node)
    length(children) >= 2 || return
    name = julia_dotted_name(first(children)); name === nothing && return
    symbol = julia_declaration!(extraction, scope, :module, name, node;
        metadata=Dict("baremodule" => startswith(lstrip(julia_syntax_text(node; maximum=8*1024*1024)), "baremodule")))
    inner = JuliaSyntaxScope(symbol.id, symbol.qualified_name, symbol.qualified_name, :module)
    for child in children[2:end]; julia_walk!(extraction, child, inner, depth + 1); end
end

function julia_walk_method!(extraction, node, scope, depth; short=false, macro_method=false)
    children = julia_node_children(node); isempty(children) && return false
    signature = macro_method ? nothing : julia_method_signature(first(children))
    if macro_method
        call = julia_signature_call(first(children))
        call === nothing && return false
        arguments = julia_node_children(call); isempty(arguments) && return false
        name = julia_dotted_name(first(arguments)); name === nothing && return false
        signature = Dict{String,Any}("callable" => "@" * name, "signature" => julia_syntax_text(first(children)),
            "dispatch_identity" => julia_syntax_identity(first(children)), "compiler_confirmed" => false)
    end
    signature === nothing && return false
    callable = signature["callable"]
    name = startswith(callable, "(") ? callable : String(last(split(callable, '.')))
    qualified = occursin('.', callable) && !startswith(callable, "(") ? callable : julia_qualified_name(scope, callable)
    details = merge(signature, Dict("short_form" => short, "macro_expanded" => false,
        "declared_in" => scope.qualification, "callable_object" => startswith(callable, "(")))
    symbol = julia_declaration!(extraction, scope, macro_method ? :macro : :method, name, node;
        metadata=details, identity=signature["dispatch_identity"], qualification=qualified)
    inner = JuliaSyntaxScope(symbol.id, symbol.qualified_name, scope.module_name, :method)
    # Signature expressions may have effects when loaded. We index their text,
    # without representing them as calls from the function body.
    for child in children[2:end]; julia_walk!(extraction, child, inner, depth + 1); end
    true
end

function julia_walk_type!(extraction, node, scope, depth)
    children = julia_node_children(node); isempty(children) && return
    header = first(children); name_node = julia_name_node(header)
    name_node === nothing && return
    name = julia_syntax_text(name_node); kind = julia_node_kind(node)
    metadata = Dict{String,Any}("declaration" => julia_syntax_text(header), "type_kind" => kind,
        "mutable" => kind == "struct" && startswith(lstrip(julia_syntax_text(node; maximum=8*1024*1024)), "mutable"))
    if julia_node_kind(header) == "<:" && length(julia_node_children(header)) == 2
        metadata["supertype"] = julia_syntax_text(julia_node_children(header)[2])
    end
    symbol = julia_declaration!(extraction, scope, :type, name, node; metadata)
    if haskey(metadata, "supertype")
        push!(extraction.supertypes, (symbol.id, metadata["supertype"], julia_node_range(extraction, header)))
    end
    inner = JuliaSyntaxScope(symbol.id, symbol.qualified_name, scope.module_name, :type)
    for child in children[2:end]; julia_walk!(extraction, child, inner, depth + 1); end
end

function julia_walk_binding!(extraction, node, scope, depth)
    children = julia_node_children(node)
    if scope.context_kind == :type && julia_node_kind(node) == "::" && length(children) == 2
        name = julia_dotted_name(children[1]); name === nothing && return
        julia_declaration!(extraction, scope, :field, name, node;
            metadata=Dict("annotation" => julia_syntax_text(children[2])))
        return
    end
    if julia_node_kind(node) == "=" && length(children) == 2
        left = children[1]
        name = julia_dotted_name(left)
        if name !== nothing && scope.context_kind in (:file, :module, :type)
            julia_declaration!(extraction, scope, scope.context_kind == :type ? :field : :binding,
                name, node; metadata=Dict("assignment_only" => true))
        end
        julia_walk!(extraction, children[2], scope, depth + 1)
        return
    end
    for child in children; julia_walk!(extraction, child, scope, depth + 1); end
end

function julia_link_local_types!(extraction::JuliaSyntaxExtraction)
    types = [symbol for symbol in extraction.symbols if symbol.kind == :type]
    for (id, text, location) in extraction.supertypes
        # Only a unique local declaration is linked. Qualified/parametric and
        # imported names need compiler-aware resolution and remain raw evidence.
        candidates = [symbol for symbol in types if symbol.name == text || symbol.qualified_name == text]
        length(candidates) == 1 || continue
        candidate = only(candidates)
        push!(extraction.relations, Relation(id, candidate.id, :inherits, location;
            confidence=0.55, provenance="julia_unique_local_type_candidate"))
    end
end
