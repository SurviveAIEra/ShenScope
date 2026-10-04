function julia_signature_call(node)
    kind = julia_node_kind(node); children = julia_node_children(node)
    kind == "call" && return node
    kind in ("where", "::", "parens") && !isempty(children) && return julia_signature_call(first(children))
    nothing
end

function julia_signature_constraints(node)
    constraints = Dict{String,Any}[]
    current = node
    for _ in 1:JULIA_SYNTAX_MAX_DEPTH
        kind = julia_node_kind(current); children = julia_node_children(current)
        isempty(children) && break
        if kind == "where"
            for item in children[2:end]
                values = julia_node_kind(item) == "braces" ? julia_node_children(item) : (item,)
                for value in values
                    push!(constraints, Dict("text" => julia_syntax_text(value), "syntax" => julia_syntax_identity(value)))
                end
            end
            current = first(children)
        elseif kind == "::"
            # Return annotations can themselves contain a where expression.
            for item in children[2:end]
                append!(constraints, julia_signature_constraints(item))
            end
            current = first(children)
        elseif kind == "parens"
            current = first(children)
        else
            break
        end
    end
    constraints
end

function julia_parameter(node; keyword=false)
    original = node; default = nothing; annotation = "Any"; vararg = false
    annotation_identity = Any["Identifier", "Any"]
    current = node
    for _ in 1:JULIA_SYNTAX_MAX_DEPTH
        kind = julia_node_kind(current); children = julia_node_children(current)
        isempty(children) && break
        if kind == "=" && length(children) == 2
            default = julia_syntax_text(children[2]); current = children[1]
        elseif kind == "..." && length(children) == 1
            vararg = true; current = children[1]
        elseif kind == "::"
            annotation = julia_syntax_text(last(children))
            annotation_identity = julia_syntax_identity(last(children))
            current = length(children) == 2 ? children[1] : nothing
            break
        else
            break
        end
    end
    name = current === nothing ? "" : julia_syntax_text(current)
    Dict{String,Any}("name" => name, "annotation" => annotation, "annotation_identity" => annotation_identity, "keyword" => keyword,
        "default" => default, "optional" => default !== nothing, "vararg" => vararg,
        "syntax" => julia_syntax_text(original))
end

function julia_method_signature(node)
    call = julia_signature_call(node)
    call === nothing && return nothing
    children = julia_node_children(call)
    isempty(children) && return nothing
    callable = julia_dotted_name(first(children))
    if callable === nothing && julia_node_kind(first(children)) == "::"
        # Callable objects are recorded separately; their runtime identity is unknown.
        callable = "(" * julia_syntax_text(first(children)) * ")"
    end
    callable === nothing && return nothing
    positional = Dict{String,Any}[]; keywords = Dict{String,Any}[]
    for parameter in children[2:end]
        if julia_node_kind(parameter) == "parameters"
            append!(keywords, (julia_parameter(child; keyword=true) for child in julia_node_children(parameter)))
        else
            push!(positional, julia_parameter(parameter))
        end
    end
    minimum = count(parameter -> !parameter["optional"] && !parameter["vararg"], positional)
    vararg = any(parameter -> parameter["vararg"], positional)
    constraints = julia_signature_constraints(node)
    signature = julia_syntax_text(node)
    identity = Any[callable, [Any[parameter["annotation_identity"], parameter["vararg"], parameter["optional"]]
        for parameter in positional], [constraint["syntax"] for constraint in constraints]]
    Dict{String,Any}("callable" => callable, "signature" => signature, "positional" => positional,
        "keywords" => keywords, "where" => constraints, "minimum_arity" => minimum,
        "maximum_arity" => vararg ? nothing : length(positional), "vararg" => vararg,
        "dispatch_identity" => identity, "runtime_method_materialized" => false,
        "keyword_dispatch" => false, "compiler_confirmed" => false)
end
