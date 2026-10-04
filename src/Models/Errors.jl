const CONTEXT_ERROR_CODES = Set(["context_length_exceeded", "context_window_exceeded",
    "max_context_length_exceeded", "prompt_too_long", "input_too_long", "too_many_tokens"])

function model_context_error(value)
    value isa AbstractDict || return false
    candidates = Any[value]
    nested = get(value, "error", nothing)
    nested isa AbstractDict && push!(candidates, nested)
    response = get(value, "response", nothing)
    response isa AbstractDict && get(response, "error", nothing) isa AbstractDict && push!(candidates, response["error"])
    for error in candidates
        for key in ("code", "type")
            code = get(error, key, nothing)
            code isa AbstractString && code in CONTEXT_ERROR_CODES && return true
        end
        # Some native APIs supply no machine code. Restrict this fallback to
        # their structured invalid-request envelope and a small known vocabulary.
        get(error, "type", nothing) in ("invalid_request_error", "invalid_argument") || continue
        message = get(error, "message", nothing)
        message isa AbstractString && ncodeunits(message) <= 4096 || continue
        normalized = lowercase(message)
        any(phrase -> occursin(phrase, normalized), ("maximum context length", "context window exceeded",
            "prompt is too long", "input token count exceeds", "too many tokens")) && return true
    end
    false
end

function model_stream_error(value; message="Model returned a stream error")
    model_context_error(value) ? ShenScopeError(:context_overflow, "Model endpoint rejected the input context", false) :
        ShenScopeError(:provider, message, false)
end

function bounded_model_error_body(stream, maximum=64 * 1024)
    bytes=UInt8[]
    while !eof(stream)
        # HTTP.Stream reads currently available bytes, not the requested
        # total. Headers and error JSON can arrive in separate packets.
        append!(bytes,read(stream,min(8192,maximum+1-length(bytes))))
        length(bytes)<=maximum || return nothing
    end
    text = String(bytes)
    isvalid(text) || return nothing
    try bounded_json_object(text; maximum, max_depth=8, max_nodes=2048) catch; nothing end
end
