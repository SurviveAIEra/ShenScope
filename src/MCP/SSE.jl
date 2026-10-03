mutable struct MCPSSEDecoder
    pending::Vector{UInt8}
    data::Vector{String}
    bytes::Int
    event::String
    event_id::Union{Nothing,String}
    maximum::Int
end
MCPSSEDecoder(maximum = MCP_MAX_MESSAGE_BYTES) = MCPSSEDecoder(UInt8[], String[], 0, "message", nothing, maximum)

function mcp_sse_line!(callback::Function, id_callback::Function, decoder::MCPSSEDecoder, line::String)
    isvalid(line) || throw(ShenScopeError(:mcp_protocol, "Invalid UTF-8 in MCP SSE stream"))
    if isempty(line)
        if !isempty(decoder.data)
            decoder.event in ("message", "") || throw(ShenScopeError(:mcp_protocol, "Unsupported MCP SSE event"))
            callback(mcp_decode(join(decoder.data, "\n"); maximum = decoder.maximum))
        end
        decoder.event_id !== nothing && id_callback(decoder.event_id)
        empty!(decoder.data)
        decoder.bytes = 0
        decoder.event = "message"
        decoder.event_id = nothing
        return
    end
    startswith(line, ":") && return
    parts = split(line, ':'; limit = 2)
    field = first(parts)
    value = length(parts) == 2 ? parts[2] : ""
    startswith(value, " ") && (value = value[2:end])
    if field == "data"
        decoder.bytes += ncodeunits(value) + (isempty(decoder.data) ? 0 : 1)
        decoder.bytes <= decoder.maximum || throw(ShenScopeError(:mcp_protocol, "MCP SSE event exceeds capacity"))
        push!(decoder.data, value)
    elseif field == "event"
        ncodeunits(value) <= 128 || throw(ShenScopeError(:mcp_protocol, "MCP SSE event name exceeds capacity"))
        decoder.event = value
    elseif field == "id" && !occursin('\0', value)
        ncodeunits(value) <= 1024 || throw(ShenScopeError(:mcp_protocol, "MCP SSE event ID exceeds capacity"))
        decoder.event_id = value
    end
    nothing
end

function feed_mcp_sse!(callback::Function, id_callback::Function, decoder::MCPSSEDecoder, data::AbstractVector{UInt8})
    offset = 1
    while offset <= length(data)
        newline = findnext(==(0x0a), data, offset)
        ending = newline === nothing ? length(data) : newline - 1
        added = max(0, ending - offset + 1)
        length(decoder.pending) + added <= decoder.maximum || throw(ShenScopeError(:mcp_protocol, "MCP SSE line exceeds capacity"))
        added > 0 && append!(decoder.pending, @view data[offset:ending])
        newline === nothing && break
        !isempty(decoder.pending) && last(decoder.pending) == 0x0d && pop!(decoder.pending)
        line = String(copy(decoder.pending))
        empty!(decoder.pending)
        mcp_sse_line!(callback, id_callback, decoder, line)
        offset = newline + 1
    end
    nothing
end

function finish_mcp_sse!(callback::Function, id_callback::Function, decoder::MCPSSEDecoder)
    if !isempty(decoder.pending)
        mcp_sse_line!(callback, id_callback, decoder, String(copy(decoder.pending)))
        empty!(decoder.pending)
    end
    mcp_sse_line!(callback, id_callback, decoder, "")
end
