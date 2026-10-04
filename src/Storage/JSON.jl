function bounded_json_object(raw::AbstractString; maximum=1024 * 1024, max_depth=16,
        max_nodes=16384, max_string_bytes=maximum, error_code=:protocol)
    function reject(message)
        throw(ShenScopeError(error_code, message))
    end
    ncodeunits(raw) <= maximum && isvalid(raw) || reject("JSON source exceeds capacity or has invalid UTF-8")
    bytes = codeunits(raw)
    containers = UInt8[]
    fields = Union{Nothing,Set{String}}[]
    quoted = false; escaped = false; quote_start = 0; closed = false; started = false; nodes = 0
    for (index, byte) in enumerate(bytes)
        if quoted
            index - quote_start <= max_string_bytes || reject("JSON string exceeds capacity")
            if escaped
                escaped = false
            elseif byte == 0x5c
                escaped = true
            elseif byte == 0x22
                quoted = false
                after = index + 1
                while after <= length(bytes) && bytes[after] in (0x20, 0x09, 0x0a, 0x0d); after += 1; end
                if !isempty(containers) && containers[end] == 0x7b && after <= length(bytes) && bytes[after] == 0x3a
                    key = try String(JSON3.read(copy(bytes[quote_start:index]))) catch; reject("Invalid JSON object key") end
                    key in fields[end] && reject("Duplicate JSON object fields are not allowed")
                    push!(fields[end], key)
                end
            end
            continue
        end
        byte in (0x20, 0x09, 0x0a, 0x0d) && continue
        closed && reject("JSON source contains trailing data")
        if !started
            byte == 0x7b || reject("JSON source must be an object")
            started = true
        end
        if byte == 0x22
            quoted = true; quote_start = index
        elseif byte in (0x7b, 0x5b)
            push!(containers, byte); push!(fields, byte == 0x7b ? Set{String}() : nothing)
            length(containers) <= max_depth || reject("JSON nesting exceeds capacity")
            nodes += 1
        elseif byte in (0x7d, 0x5d)
            !isempty(containers) && containers[end] == (byte == 0x7d ? 0x7b : 0x5b) || reject("JSON containers are unbalanced")
            pop!(containers); pop!(fields)
            closed = isempty(containers)
        elseif byte in (0x2c, 0x3a)
            nodes += 1
        end
        nodes <= max_nodes || reject("JSON element count exceeds capacity")
    end
    started && closed && !quoted && isempty(containers) || reject("JSON source is incomplete")
    value = try parsejson(raw) catch; reject("JSON source is malformed") end
    value isa AbstractDict || reject("JSON source must be an object")
    pending = Any[value]
    while !isempty(pending)
        item = pop!(pending)
        if item isa AbstractDict
            append!(pending, values(item))
        elseif item isa AbstractVector
            append!(pending, item)
        elseif item isa AbstractFloat
            isfinite(item) || reject("JSON numbers must be finite")
        elseif item isa AbstractString
            isvalid(item) || reject("JSON string contains invalid Unicode")
        end
    end
    value
end
