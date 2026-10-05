mutable struct LanguageFrameDecoder
    header::Vector{UInt8}
    body::Vector{UInt8}
    expected::Union{Nothing,Int}
    maximum_header::Int
    maximum_body::Int
end

function LanguageFrameDecoder(; maximum_header=8192, maximum_body=4*1024^2)
    128 <= maximum_header <= 65536 && 128 <= maximum_body <= 8*1024^2 ||
        throw(ArgumentError("Invalid language-service frame capacities"))
    LanguageFrameDecoder(UInt8[], UInt8[], nothing, Int(maximum_header), Int(maximum_body))
end

function language_header_length(header::Vector{UInt8}, maximum::Int)
    all(byte -> 0x20 <= byte <= 0x7e || byte in (0x0d, 0x0a), header) ||
        throw(ShenScopeError(:language_protocol, "Language-service header must be ASCII"))
    text = String(copy(header))
    endswith(text, "\r\n\r\n") || throw(ShenScopeError(:language_protocol, "Language-service header terminator is invalid"))
    found = nothing
    for line in split(text[1:end-4], "\r\n")
        parts = split(line, ':'; limit=2)
        length(parts) == 2 || throw(ShenScopeError(:language_protocol, "Malformed language-service header"))
        name, value = lowercase(strip(parts[1])), strip(parts[2])
        if name == "content-length"
            found === nothing || throw(ShenScopeError(:language_protocol, "Duplicate language-service content length"))
            occursin(r"^[0-9]+$", value) || throw(ShenScopeError(:language_protocol, "Invalid language-service content length"))
            found = tryparse(Int, value)
            found !== nothing && 1 <= found <= maximum ||
                throw(ShenScopeError(:language_protocol, "Language-service body exceeds capacity"))
        elseif name == "content-type"
            occursin(r"(?i)^application/(?:vscode-jsonrpc|json)(?:\s*;\s*charset\s*=\s*utf-?8)?$", value) ||
                throw(ShenScopeError(:language_protocol, "Unsupported language-service content encoding"))
        end
    end
    found === nothing && throw(ShenScopeError(:language_protocol, "Language-service content length is missing"))
    found
end

function decode_language_message(raw::String, maximum::Int)
    try
        mcp_decode(raw; maximum)
    catch cause
        cause isa ShenScopeError || rethrow()
        throw(ShenScopeError(:language_protocol, "Language server sent an invalid bounded JSON-RPC message"))
    end
end

function feed_language_frames!(callback::Function, decoder::LanguageFrameDecoder, data::AbstractVector{UInt8})
    cursor = 1
    while cursor <= length(data)
        if decoder.expected === nothing
            push!(decoder.header, data[cursor])
            cursor += 1
            length(decoder.header) <= decoder.maximum_header ||
                throw(ShenScopeError(:language_protocol, "Language-service header exceeds capacity"))
            if length(decoder.header) >= 4 && decoder.header[end-3:end] == UInt8[0x0d,0x0a,0x0d,0x0a]
                decoder.expected = language_header_length(decoder.header, decoder.maximum_body)
                empty!(decoder.header)
            end
        else
            available = min(decoder.expected - length(decoder.body), length(data) - cursor + 1)
            append!(decoder.body, @view data[cursor:cursor+available-1])
            cursor += available
            if length(decoder.body) == decoder.expected
                raw = String(copy(decoder.body))
                empty!(decoder.body)
                decoder.expected = nothing
                callback(decode_language_message(raw, decoder.maximum_body))
            end
        end
    end
    nothing
end

function finish_language_frames!(callback::Function, decoder::LanguageFrameDecoder)
    isempty(decoder.header) && isempty(decoder.body) && decoder.expected === nothing ||
        throw(ShenScopeError(:language_protocol, "Language-service stream ended inside a frame"))
    nothing
end

language_frame(raw::AbstractString) = "Content-Length: " * string(ncodeunits(raw)) * "\r\n\r\n" * raw

function language_encoded_frame(message::AbstractDict; maximum=4*1024^2)
    raw = bounded_canonical_json(message; maximum, max_depth=64, max_nodes=100_000)
    decode_language_message(raw, Int(maximum))
    language_frame(raw)
end
