mutable struct UTF8StreamDecoder
    pending::Vector{UInt8}
    finished::Bool
end
UTF8StreamDecoder() = UTF8StreamDecoder(UInt8[], false)

utf8_continuation(byte::UInt8) = 0x80 <= byte <= 0xbf

function utf8_sequence_length(byte::UInt8)
    byte <= 0x7f && return 1
    0xc2 <= byte <= 0xdf && return 2
    0xe0 <= byte <= 0xef && return 3
    0xf0 <= byte <= 0xf4 && return 4
    0
end

function utf8_second_valid(first::UInt8, second::UInt8)
    utf8_continuation(second) || return false
    first == 0xe0 && return second >= 0xa0
    first == 0xed && return second <= 0x9f
    first == 0xf0 && return second >= 0x90
    first == 0xf4 && return second <= 0x8f
    true
end

function feed_utf8!(decoder::UTF8StreamDecoder, chunk::AbstractVector{UInt8})
    decoder.finished && throw(ShenScopeError(:encoding_state, "UTF-8 stream is already finished"))
    length(chunk) <= 8192 || throw(ShenScopeError(:encoding_size, "UTF-8 event chunk exceeds capacity"))
    bytes = vcat(decoder.pending, chunk)
    empty!(decoder.pending)
    output = IOBuffer()
    offset = 1
    while offset <= length(bytes)
        first = bytes[offset]
        count = utf8_sequence_length(first)
        if count == 1
            write(output, first); offset += 1; continue
        elseif count == 0
            write(output, '�'); offset += 1; continue
        end
        available = min(count, length(bytes) - offset + 1)
        valid = available < 2 || utf8_second_valid(first, bytes[offset + 1])
        for index in offset + 2:offset + available - 1
            utf8_continuation(bytes[index]) || (valid = false; break)
        end
        if !valid
            write(output, '�'); offset += 1; continue
        elseif available < count
            append!(decoder.pending, @view bytes[offset:end])
            break
        end
        write(output, @view bytes[offset:offset + count - 1])
        offset += count
    end
    length(decoder.pending) <= 3 || throw(ShenScopeError(:encoding_state, "UTF-8 decoder retained an invalid prefix"))
    String(take!(output))
end

function finish_utf8!(decoder::UTF8StreamDecoder)
    decoder.finished && return ""
    decoder.finished = true
    incomplete = !isempty(decoder.pending)
    empty!(decoder.pending)
    incomplete ? "�" : ""
end
