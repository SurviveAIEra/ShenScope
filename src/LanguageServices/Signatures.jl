function language_signature_documentation(value)
    value === nothing && return nothing
    fragment = language_hover_content(value)
    text = fragment["text"]
    fragment["text"] = cliptext(text, 16*1024)
    fragment["truncated"] = ncodeunits(text) > 16*1024
    fragment
end

function language_parameter_label(value, label::String)
    value isa AbstractString && return Dict("text" => language_text(value, "signature parameter label", 4096; empty=true))
    value isa AbstractVector && length(value) == 2 ||
        throw(ShenScopeError(:language_protocol, "Parameter label must be text or a UTF-16 offset pair"))
    first = language_integer(value[1], "parameter label start", 0, 16384)
    after = language_integer(value[2], "parameter label end", first, 16384)
    # Reuse exact UTF-16 boundary validation on this one-line label. Labels
    # containing line breaks cannot be addressed by an offset pair here.
    !occursin('\n', label) && !occursin('\r', label) ||
        throw(ShenScopeError(:language_protocol, "Offset parameter labels require a single-line signature"))
    source = SourceMap("signature", label; unicode_line_separators=false)
    start = utf16_byte_column(source, 1, first)
    ending = utf16_byte_column(source, 1, after)
    Dict("utf16_offsets" => [first, after], "text" => String(SubString(label, start, prevind(label, ending))))
end

function normalize_language_signature_help(value; maximum=32)
    value === nothing && return Dict("available" => false, "signatures" => Any[])
    value isa AbstractDict && get(value, "signatures", nothing) isa AbstractVector ||
        throw(ShenScopeError(:language_protocol, "Signature help requires a signatures array"))
    supplied = value["signatures"]
    length(supplied) <= 512 || throw(ShenScopeError(:language_protocol, "Too many language signatures"))
    signatures = Dict{String,Any}[]
    for row in Iterators.take(supplied, maximum)
        row isa AbstractDict && haskey(row, "label") || throw(ShenScopeError(:language_protocol, "Signature lacks a label"))
        label = language_text(row["label"], "signature label", 16*1024)
        parameters = get(row, "parameters", Any[])
        parameters isa AbstractVector && length(parameters) <= 256 || throw(ShenScopeError(:language_protocol, "Too many signature parameters"))
        normalized = Dict{String,Any}[]
        for parameter in parameters
            parameter isa AbstractDict && haskey(parameter, "label") || throw(ShenScopeError(:language_protocol, "Parameter lacks a label"))
            push!(normalized, Dict("label" => language_parameter_label(parameter["label"], label),
                "documentation" => language_signature_documentation(get(parameter, "documentation", nothing))))
        end
        selected = get(row, "activeParameter", nothing)
        selected === nothing || (selected = language_integer(selected, "active signature parameter", 0, max(0,length(parameters)-1)))
        push!(signatures, Dict("label" => label, "parameters" => normalized, "active_parameter" => selected,
            "documentation" => language_signature_documentation(get(row, "documentation", nothing))))
    end
    active = get(value, "activeSignature", nothing)
    active === nothing || (active = language_integer(active, "active signature", 0, max(0,length(supplied)-1)))
    parameter = get(value, "activeParameter", nothing)
    parameter === nothing || (parameter = language_integer(parameter, "active parameter", 0, 255))
    Dict("available" => !isempty(signatures), "signatures" => signatures, "active_signature" => active,
        "active_parameter" => parameter, "reported_signatures" => length(supplied),
        "projection_truncated" => length(supplied) > length(signatures))
end
