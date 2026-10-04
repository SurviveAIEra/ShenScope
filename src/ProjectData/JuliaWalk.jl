function julia_record_import!(extraction, node, scope)
    length(extraction.imports) < JULIA_SYNTAX_MAX_CALLS || throw(ShenScopeError(:graph, "Julia import limit reached"))
    kind = julia_node_kind(node)
    push!(extraction.imports, Dict("kind" => kind, "text" => julia_syntax_text(node),
        "module" => scope.module_name, "location" => range_dict(julia_node_range(extraction, node)),
        "resolved" => false, "compiler_confirmed" => false))
end

function julia_record_export!(extraction, node, scope)
    length(extraction.exports) < JULIA_SYNTAX_MAX_CALLS || throw(ShenScopeError(:graph, "Julia export limit reached"))
    push!(extraction.exports, Dict("kind" => julia_node_kind(node), "text" => julia_syntax_text(node),
        "module" => scope.module_name, "location" => range_dict(julia_node_range(extraction, node)),
        "compiler_confirmed" => false))
end

function julia_record_include!(extraction, node, scope, arguments)
    length(arguments) == 1 || return
    argument = only(arguments); value = julia_literal_string(argument)
    record = Dict{String,Any}("location" => range_dict(julia_node_range(extraction, node)),
        "module" => scope.module_name, "expression" => julia_syntax_text(argument),
        "literal" => value, "resolved" => false, "executed" => false)
    if value !== nothing && !isabspath(value) && !occursin('\0', value)
        relative = replace(normpath(joinpath(dirname(extraction.source.path), value)), '\\' => '/')
        if relative != ".." && !startswith(relative, "../")
            # Lexical relative target only; do not read or follow another file.
            record["candidate_path"] = relative
            record["resolved"] = true
            record["resolution"] = "literal_relative_path_only"
        else
            record["reason"] = "outside_workspace"
        end
    else
        record["reason"] = value === nothing ? "dynamic_expression" : "unsupported_path"
    end
    length(extraction.includes) < JULIA_SYNTAX_MAX_CALLS || throw(ShenScopeError(:graph, "Julia include limit reached"))
    push!(extraction.includes, record)
end

function julia_record_call!(extraction, node, scope; macro_call=false)
    children = julia_node_children(node); isempty(children) && return
    name = julia_dotted_name(first(children))
    location = julia_node_range(extraction, node)
    length(extraction.calls) < JULIA_SYNTAX_MAX_CALLS || throw(ShenScopeError(:graph, "Julia call limit reached"))
    positional = [child for child in children[2:end] if julia_node_kind(child) != "parameters"]
    keywords = [julia_syntax_text(item) for child in children[2:end]
        if julia_node_kind(child) == "parameters" for item in julia_node_children(child)]
    record = Dict{String,Any}("owner" => scope.owner.value, "name" => name,
        "expression" => julia_syntax_text(first(children)), "module" => scope.module_name,
        "location" => range_dict(location), "positional_count" => length(positional),
        "splat" => any(child -> julia_node_kind(child) == "...", positional), "keywords" => keywords,
        "qualified" => name === nothing || occursin('.', name), "macro" => macro_call,
        "resolved" => false, "compiler_confirmed" => false)
    push!(extraction.calls, record)
    if name !== nothing && !macro_call
        push!(extraction.references, CallReference(scope.owner, String(last(split(name, '.'))), location, record["qualified"]))
        name in ("include", "Base.include") && julia_record_include!(extraction, node, scope, positional)
    end
end

function julia_walk!(extraction::JuliaSyntaxExtraction, node, scope::JuliaSyntaxScope, depth::Int)
    julia_syntax_checkpoint!(extraction, depth)
    kind = julia_node_kind(node)
    if kind == "module"
        return julia_walk_module!(extraction, node, scope, depth)
    elseif kind == "function"
        julia_walk_method!(extraction, node, scope, depth) && return
    elseif kind == "macro"
        julia_walk_method!(extraction, node, scope, depth; macro_method=true) && return
    elseif kind == "="
        julia_walk_method!(extraction, node, scope, depth; short=true) && return
        return julia_walk_binding!(extraction, node, scope, depth)
    elseif kind in ("struct", "abstract", "primitive")
        return julia_walk_type!(extraction, node, scope, depth)
    elseif kind in ("using", "import")
        return julia_record_import!(extraction, node, scope)
    elseif kind in ("export", "public")
        return julia_record_export!(extraction, node, scope)
    elseif kind == "::" && scope.context_kind == :type
        return julia_walk_binding!(extraction, node, scope, depth)
    elseif kind in ("quote", "inert")
        # Quoted declarations/calls are data. Macro expansion is deliberately absent.
        return
    elseif kind == "macrocall"
        julia_record_call!(extraction, node, scope; macro_call=true)
        return
    elseif kind in ("call", "dotcall")
        julia_record_call!(extraction, node, scope)
    elseif isempty(julia_node_children(node)) && kind == "Identifier" && scope.context_kind == :type
        julia_declaration!(extraction, scope, :field, julia_syntax_text(node), node;
            metadata=Dict("annotation" => "Any"))
        return
    end
    for child in julia_node_children(node); julia_walk!(extraction, child, scope, depth + 1); end
end
