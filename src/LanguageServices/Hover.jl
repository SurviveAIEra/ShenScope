function language_hover_content(value)
    if value isa AbstractString
        return Dict{String,Any}("kind" => "markdown", "text" => String(value))
    end
    value isa AbstractDict && haskey(value, "value") ||
        throw(ShenScopeError(:language_protocol, "Invalid language hover content"))
    text = language_text(value["value"], "hover text", 512*1024; empty=true)
    if haskey(value, "kind")
        value["kind"] in ("plaintext", "markdown") ||
            throw(ShenScopeError(:language_protocol, "Invalid language hover format"))
        return Dict{String,Any}("kind" => value["kind"], "text" => text)
    end
    language = language_text(get(value, "language", ""), "hover code language", 64; empty=true)
    Dict{String,Any}("kind" => "code", "language" => language, "text" => text)
end

function normalize_language_hover(value, snapshot::WorkspaceSourceSnapshot; maximum_bytes=64*1024)
    value === nothing && return Dict("available" => false, "contents" => Any[])
    value isa AbstractDict && haskey(value, "contents") ||
        throw(ShenScopeError(:language_protocol, "Language hover lacks contents"))
    supplied = value["contents"]
    rows = supplied isa AbstractVector ? supplied : Any[supplied]
    length(rows) <= 128 || throw(ShenScopeError(:language_protocol, "Language hover contains too many fragments"))
    fragments = Dict{String,Any}[]
    bytes = 0
    truncated = false
    for row in rows
        fragment = language_hover_content(row)
        text = fragment["text"]
        isvalid(text) && ncodeunits(text) <= 512*1024 ||
            throw(ShenScopeError(:language_protocol, "Language hover text exceeds input capacity"))
        available = maximum_bytes - bytes
        available <= 0 && (truncated = true; break)
        if ncodeunits(text) > available
            fragment["text"] = cliptext(text, available)
            fragment["truncated"] = true
            truncated = true
        end
        push!(fragments, fragment)
        bytes += ncodeunits(fragment["text"])
    end
    location = get(value, "range", nothing)
    result = Dict{String,Any}("available" => true, "path" => snapshot.path,
        "source_sha256" => snapshot.sha256, "contents" => fragments,
        "projection_truncated" => truncated, "content_is_untrusted_server_text" => true)
    location === nothing || (result["location"] = range_dict(language_range(snapshot.source, location)))
    result
end
