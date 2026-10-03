struct SourceMap
    path::String
    source::String
    starts::Vector{Int}
    ends::Vector{Int}
    checkpoints::Dict{Int,Vector{Tuple{Int,Int}}}
    mutex::ReentrantLock
end

function SourceMap(path::AbstractString, source::AbstractString; maximum=8 * 1024 * 1024)
    isvalid(source) && ncodeunits(source) <= maximum ||
        throw(ShenScopeError(:source_position, "Source exceeds capacity or is not UTF-8"))
    text = String(source)
    starts = Int[1]; ends = Int[]
    index = firstindex(text)
    while index <= ncodeunits(text)
        character = text[index]
        after = nextind(text, index)
        if character in ('\r', '\n', '\u2028', '\u2029')
            push!(ends, index)
            character == '\r' && after <= ncodeunits(text) && text[after] == '\n' && (after = nextind(text, after))
            push!(starts, after)
        end
        index = after
    end
    push!(ends, ncodeunits(text) + 1)
    SourceMap(String(path), text, starts, ends, Dict{Int,Vector{Tuple{Int,Int}}}(), ReentrantLock())
end

function source_line_checkpoints(source::SourceMap, line::Integer)
    start, ending = source_line_bounds(source, line)
    ending - start <= 256 && return Tuple{Int,Int}[(0, start)]
    lock(source.mutex) do
        get!(source.checkpoints, Int(line)) do
            result = Tuple{Int,Int}[(0, start)]; index = start; units = 0
            while index < ending
                units += UInt32(source.source[index]) > 0xffff ? 2 : 1
                index = nextind(source.source, index)
                units - result[end][1] >= 64 && push!(result, (units, index))
            end
            result
        end
    end
end

function source_line_bounds(source::SourceMap, line::Integer)
    !(line isa Bool) && 1 <= line <= length(source.starts) ||
        throw(ShenScopeError(:source_position, "Line is outside the source"))
    source.starts[line], source.ends[line]
end

function source_byte_index(source::SourceMap, line::Integer, column::Integer)
    start, ending = source_line_bounds(source, line)
    !(column isa Bool) && 1 <= column <= ending - start + 1 ||
        throw(ShenScopeError(:source_position, "Byte column is outside the source line"))
    index = start + column - 1
    (index == ending || isvalid(source.source, index)) ||
        throw(ShenScopeError(:source_position, "Byte column splits a UTF-8 code point"))
    index
end

function utf16_byte_column(source::SourceMap, line::Integer, character::Integer)
    !(character isa Bool) && 0 <= character <= 8 * 1024 * 1024 ||
        throw(ShenScopeError(:source_position, "Invalid UTF-16 character offset"))
    start, ending = source_line_bounds(source, line)
    checkpoints = source_line_checkpoints(source, line)
    seat = searchsortedlast(checkpoints, (Int(character), typemax(Int)))
    units, index = checkpoints[max(1, seat)]
    while units < character && index < ending
        width = UInt32(source.source[index]) > 0xffff ? 2 : 1
        units + width <= character || throw(ShenScopeError(:source_position, "UTF-16 offset splits a surrogate pair"))
        units += width; index = nextind(source.source, index)
    end
    units == character || throw(ShenScopeError(:source_position, "UTF-16 offset is outside the source line"))
    index - start + 1
end

function byte_utf16_character(source::SourceMap, line::Integer, column::Integer)
    ending = source_byte_index(source, line, column)
    checkpoints = source_line_checkpoints(source, line)
    seat = searchsortedlast(checkpoints, (0, ending); by=last)
    units, start = checkpoints[max(1, seat)]
    for character in SubString(source.source, start, prevind(source.source, ending))
        units += UInt32(character) > 0xffff ? 2 : 1
    end
    units
end

function source_position(source::SourceMap, index::Integer)
    !(index isa Bool) && 1 <= index <= ncodeunits(source.source) + 1 ||
        throw(ShenScopeError(:source_position, "Source byte offset is outside the file"))
    line = searchsortedlast(source.starts, index)
    column = index - source.starts[line] + 1
    source_byte_index(source, line, column)
    (line, column)
end

function compiler_position(source::SourceMap, value)
    value isa AbstractDict && Set(keys(value)) == Set(["line", "character"]) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler position has unexpected fields"))
    line = value["line"]; character = value["character"]
    line isa Integer && !(line isa Bool) && character isa Integer && !(character isa Bool) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler position must use integer coordinates"))
    0 <= line < length(source.starts) || throw(ShenScopeError(:compiler_protocol, "Compiler line is outside the source"))
    (Int(line) + 1, utf16_byte_column(source, Int(line) + 1, character))
end

function compiler_range(source::SourceMap, value)
    value isa AbstractDict && Set(keys(value)) == Set(["start", "end"]) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler range has unexpected fields"))
    first_line, first_column = compiler_position(source, value["start"])
    last_line, last_column = compiler_position(source, value["end"])
    (first_line, first_column) <= (last_line, last_column) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler range is reversed"))
    SourceRange(source.path, first_line, last_line; start_column=first_column, end_column=last_column)
end

function source_range_indices(source::SourceMap, range::SourceRange)
    range.file == source.path || throw(ShenScopeError(:source_position, "Range belongs to another source file"))
    start = source_byte_index(source, range.start_line, range.start_column)
    ending = source_byte_index(source, range.end_line, range.end_column)
    start <= ending || throw(ShenScopeError(:source_position, "Source range is reversed"))
    start, ending
end

function source_range_text(source::SourceMap, range::SourceRange)
    start, ending = source_range_indices(source, range)
    start == ending ? "" : String(SubString(source.source, start, prevind(source.source, ending)))
end

function range_contains(range::SourceRange, line::Integer, column::Integer)
    (range.start_line, range.start_column) <= (line, column) < (range.end_line, range.end_column)
end

function range_encloses(outer::SourceRange, inner::SourceRange)
    outer.file == inner.file && (outer.start_line, outer.start_column) <= (inner.start_line, inner.start_column) &&
        (inner.end_line, inner.end_column) <= (outer.end_line, outer.end_column)
end

function range_utf16(source::SourceMap, range::SourceRange)
    source_range_indices(source, range)
    Dict("start" => Dict("line" => range.start_line - 1,
        "character" => byte_utf16_character(source, range.start_line, range.start_column)),
        "end" => Dict("line" => range.end_line - 1,
        "character" => byte_utf16_character(source, range.end_line, range.end_column)))
end
