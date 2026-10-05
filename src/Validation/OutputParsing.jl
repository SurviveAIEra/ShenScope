function validation_frame(path, line, column, level, message, code, stream, ordinal)
    parsed_line = tryparse(Int, String(line))
    parsed_column = column === nothing ? nothing : tryparse(Int, String(column))
    parsed_line !== nothing && 1 <= parsed_line <= 8*1024^2 &&
        (column === nothing || parsed_column !== nothing && 1 <= parsed_column <= 8*1024^2) || return nothing
    isvalid(path) && 1 <= ncodeunits(path) <= 4096 && !occursin('\0', path) || return nothing
    severity = level in ("fatal error", "error", "SyntaxError", "IndentationError", "TabError") ? "error" :
        level == "warning" ? "warning" : "information"
    ValidationDiagnosticFrame(String(path), parsed_line, parsed_column, severity,
        cliptext(String(message), 16*1024), code === nothing ? nothing : String(code), stream, ordinal)
end

function parse_validation_output(text::AbstractString, family::String, stream::String, limits::ValidationLimits)
    validation_family(family)
    stream in ("stdout", "stderr") || throw(ShenScopeError(:validation, "Unknown validation stream"))
    frames = ValidationDiagnosticFrame[]
    scanned = 0
    oversized = 0
    omitted = 0
    python_source = nothing
    python_line = nothing
    python_ordinal = 0
    for (ordinal, raw) in enumerate(eachsplit(text, '\n'))
        if scanned >= limits.maximum_lines
            omitted += 1
            continue
        end
        scanned += 1
        if ncodeunits(raw) > limits.maximum_line_bytes
            oversized += 1
            continue
        end
        line = replace(String(raw), r"\e\[[0-9;]*[A-Za-z]" => "")
        family == "none" && continue
        frame = nothing
        if family == "python"
            position = match(r"^\s*File \"([^\"]+)\", line ([0-9]+)(?:,.*)?$", line)
            if position !== nothing
                python_source, python_line = position.captures
                python_ordinal = ordinal
            elseif python_source !== nothing && ordinal-python_ordinal <= 8
                failure = match(r"^(SyntaxError|IndentationError|TabError):\s*(.+)$", strip(line))
                failure === nothing || (frame = validation_frame(python_source, python_line, nothing,
                    failure.captures[1], failure.captures[2], failure.captures[1], stream, ordinal))
            end
        elseif family == "typescript"
            result = match(r"^(.+)\(([0-9]+),([0-9]+)\):\s*(error|warning)\s+([A-Za-z]+[0-9]+):\s*(.+)$", line)
            result === nothing || (frame = validation_frame(result.captures[1], result.captures[2], result.captures[3],
                result.captures[4], result.captures[6], result.captures[5], stream, ordinal))
        else
            result = match(r"^(.+?):([0-9]+)(?::([0-9]+))?:\s*(fatal error|error|warning|note):\s*(.+)$", line)
            if result !== nothing
                frame = validation_frame(result.captures[1], result.captures[2], result.captures[3],
                    result.captures[4], result.captures[5], nothing, stream, ordinal)
            elseif family in ("go", "generic")
                result = match(r"^(.+?):([0-9]+):([0-9]+):\s*(.+)$", line)
                result === nothing || (frame = validation_frame(result.captures[1], result.captures[2], result.captures[3],
                    "error", result.captures[4], nothing, stream, ordinal))
            end
        end
        frame === nothing && continue
        if length(frames) >= limits.maximum_diagnostics
            omitted += 1
        else
            push!(frames, frame)
        end
    end
    frames, Dict("lines_scanned" => scanned, "oversize_lines_omitted" => oversized,
        "rows_omitted" => omitted, "matched_diagnostics" => length(frames))
end

function validation_frame_path(ctx::RuntimeContext, cwd::String, frame::ValidationDiagnosticFrame)
    path = isabspath(frame.path) ? frame.path : normpath(joinpath(cwd, frame.path))
    try
        workspace_snapshot_path(ctx, path; must_exist=false)[2]
    catch cause
        cause isa ShenScopeError || rethrow()
        nothing
    end
end

function validation_frame_location(frame::ValidationDiagnosticFrame, source::SourceMap, column_unit::String)
    frame.line <= length(source.starts) || throw(ShenScopeError(:validation, "Reported diagnostic line is outside the captured source"))
    start, ending = source_line_bounds(source, frame.line)
    if frame.column === nothing || column_unit == "unknown"
        return SourceRange(source.path, frame.line, frame.line;
            start_column=1, end_column=ending-start+1), "reported_line"
    end
    column = frame.column
    if column_unit == "utf16"
        column = utf16_byte_column(source, frame.line, column-1)
    elseif column_unit == "unicode_scalar"
        index = start
        for count in 1:column-1
            index < ending || throw(ShenScopeError(:validation, "Reported scalar column exceeds its line"))
            index = nextind(source.source, index)
        end
        column = index-start+1
    end
    index = source_byte_index(source, frame.line, column)
    after = index == ending ? column : nextind(source.source,index)-start+1
    SourceRange(source.path, frame.line, frame.line; start_column=column, end_column=after), "reported_column"
end
