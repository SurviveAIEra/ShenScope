function compiler_jsonc(text::AbstractString; maximum=256 * 1024)
    isvalid(text) && ncodeunits(text) <= maximum ||
        throw(ShenScopeError(:compiler_config, "Compiler configuration exceeds capacity or is not UTF-8"))
    bytes = Vector{UInt8}(codeunits(text)); index = 1
    quoted = false; escaped = false
    if length(bytes) >= 3 && bytes[1:3] == UInt8[0xef, 0xbb, 0xbf]
        bytes[1:3] .= 0x20; index = 4
    end
    while index <= length(bytes)
        byte = bytes[index]
        if quoted
            if escaped; escaped = false
            elseif byte == 0x5c; escaped = true
            elseif byte == 0x22; quoted = false
            end
        elseif byte == 0x22
            quoted = true
        elseif byte == 0x2f && index < length(bytes) && bytes[index + 1] in (0x2f, 0x2a)
            block = bytes[index + 1] == 0x2a
            bytes[index:index + 1] .= 0x20; index += 2
            closed = !block
            while index <= length(bytes)
                if block && index < length(bytes) && bytes[index] == 0x2a && bytes[index + 1] == 0x2f
                    bytes[index:index + 1] .= 0x20; index += 1; closed = true; break
                elseif !block && bytes[index] in (0x0a, 0x0d)
                    break
                end
                bytes[index] in (0x0a, 0x0d) || (bytes[index] = 0x20)
                index += 1
            end
            closed || throw(ShenScopeError(:compiler_config, "Compiler configuration has an unterminated comment"))
        end
        index += 1
    end
    quoted && throw(ShenScopeError(:compiler_config, "Compiler configuration has an unterminated string"))
    quoted = false; escaped = false
    for index in eachindex(bytes)
        byte = bytes[index]
        if quoted
            if escaped; escaped = false
            elseif byte == 0x5c; escaped = true
            elseif byte == 0x22; quoted = false
            end
        elseif byte == 0x22
            quoted = true
        elseif byte == 0x2c
            after = index + 1
            while after <= length(bytes) && bytes[after] in (0x20, 0x09, 0x0a, 0x0d); after += 1; end
            if after <= length(bytes) && bytes[after] in (0x7d, 0x5d)
                before = index - 1
                while before >= 1 && bytes[before] in (0x20, 0x09, 0x0a, 0x0d); before -= 1; end
                before >= 1 && !(bytes[before] in (0x7b, 0x5b, 0x3a, 0x2c)) ||
                    throw(ShenScopeError(:compiler_config, "Trailing comma has no preceding value"))
                bytes[index] = 0x20
            end
        end
    end
    bounded_json_object(String(bytes); maximum, max_depth=16, max_nodes=16384, error_code=:compiler_config)
end
