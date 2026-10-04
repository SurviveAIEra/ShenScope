mutable struct BoundedJSONEncoder
    output::IOBuffer
    maximum::Int
    max_depth::Int
    max_nodes::Int
    nodes::Int
end

function bounded_json_write!(encoder::BoundedJSONEncoder,value::Union{AbstractString,UInt8})
    bytes = value isa UInt8 ? 1 : ncodeunits(value)
    position(encoder.output)+bytes <= encoder.maximum || throw(ShenScopeError(:capacity,"JSON output exceeds capacity"))
    write(encoder.output,value)
    nothing
end

function bounded_json_string!(encoder::BoundedJSONEncoder,value::AbstractString)
    isvalid(value) || throw(ShenScopeError(:protocol,"JSON string is not valid UTF-8"))
    ncodeunits(value)+2 <= encoder.maximum-position(encoder.output) || throw(ShenScopeError(:capacity,"JSON string exceeds output capacity"))
    bounded_json_write!(encoder,UInt8('"'))
    escapes = Dict('"'=>"\\\"",'\\'=>"\\\\",'\b'=>"\\b",'\f'=>"\\f",'\n'=>"\\n",'\r'=>"\\r",'\t'=>"\\t")
    start = firstindex(value)
    for index in eachindex(value)
        character = value[index]
        special = haskey(escapes,character) || UInt32(character) < 0x20
        special || continue
        index > start && bounded_json_write!(encoder,SubString(value,start,prevind(value,index)))
        escaped = get(escapes,character,nothing)
        if escaped === nothing
            escaped = "\\u"*lpad(string(UInt32(character);base=16),4,'0')
        end
        bounded_json_write!(encoder,escaped)
        start = nextind(value,index)
    end
    start <= lastindex(value) && bounded_json_write!(encoder,SubString(value,start,lastindex(value)))
    bounded_json_write!(encoder,UInt8('"'))
    nothing
end

function bounded_json_encode!(encoder::BoundedJSONEncoder,value,depth::Int)
    depth <= encoder.max_depth || throw(ShenScopeError(:capacity,"JSON nesting exceeds capacity"))
    encoder.nodes += 1
    encoder.nodes <= encoder.max_nodes || throw(ShenScopeError(:capacity,"JSON node count exceeds capacity"))
    if value isa AbstractDict
        length(value) <= div(encoder.max_nodes-encoder.nodes,2) || throw(ShenScopeError(:capacity,"JSON node count exceeds capacity"))
        all(key -> key isa AbstractString,keys(value)) || throw(ShenScopeError(:protocol,"JSON object keys must be strings"))
        bounded_json_write!(encoder,UInt8('{'))
        first = true
        for key in sort!(collect(keys(value));by=string)
            first || bounded_json_write!(encoder,UInt8(','));first = false
            encoder.nodes += 1
            encoder.nodes <= encoder.max_nodes || throw(ShenScopeError(:capacity,"JSON node count exceeds capacity"))
            bounded_json_string!(encoder,key);bounded_json_write!(encoder,UInt8(':'))
            bounded_json_encode!(encoder,value[key],depth+1)
        end
        bounded_json_write!(encoder,UInt8('}'))
    elseif value isa AbstractVector || value isa Tuple
        length(value) <= encoder.max_nodes-encoder.nodes || throw(ShenScopeError(:capacity,"JSON node count exceeds capacity"))
        bounded_json_write!(encoder,UInt8('['))
        first = true
        for item in value
            first || bounded_json_write!(encoder,UInt8(','));first = false
            bounded_json_encode!(encoder,item,depth+1)
        end
        bounded_json_write!(encoder,UInt8(']'))
    elseif value isa AbstractString
        bounded_json_string!(encoder,value)
    elseif value === nothing || value isa Bool || value isa Integer || value isa AbstractFloat
        bounded_json_write!(encoder,canonical(value))
    else
        throw(ShenScopeError(:protocol,"Expected JSON-only data"))
    end
    nothing
end

function bounded_canonical_json(value;maximum=8*1024^2,max_depth=24,max_nodes=100_000)
    all(option -> option isa Integer && !(option isa Bool),(maximum,max_depth,max_nodes)) &&
        1 <= maximum <= 64*1024^2 && 1 <= max_depth <= 64 && 1 <= max_nodes <= 1_000_000 ||
        throw(ArgumentError("Invalid JSON encoding capacities"))
    encoder = BoundedJSONEncoder(IOBuffer(;maxsize=maximum,sizehint=min(maximum,8192)),Int(maximum),Int(max_depth),Int(max_nodes),0)
    bounded_json_encode!(encoder,value,0)
    String(take!(encoder.output))
end
