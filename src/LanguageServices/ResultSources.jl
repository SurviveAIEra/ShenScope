mutable struct LanguageResultSources
    context::RuntimeContext
    cache::Dict{String,WorkspaceSourceSnapshot}
    bytes::Int
    maximum_bytes::Int
    maximum_files::Int
    omitted::Dict{String,Int}
end

function LanguageResultSources(ctx::RuntimeContext; primary=nothing)
    cache = Dict{String,WorkspaceSourceSnapshot}()
    primary === nothing || (cache[primary.path] = primary)
    LanguageResultSources(ctx, cache, primary === nothing ? 0 : ncodeunits(primary.source.source),
        32*1024^2, 128, Dict())
end

function language_omit!(sources::LanguageResultSources, reason::String)
    sources.omitted[reason] = get(sources.omitted, reason, 0) + 1
    nothing
end

function verify_language_result_sources!(sources::LanguageResultSources)
    versions = Dict{String,Any}[]
    for path in sort!(collect(keys(sources.cache)))
        workspace_source_checkpoint(sources.context)
        snapshot = verify_workspace_snapshot(sources.cache[path], sources.context; tool="language.source")
        push!(versions, Dict("path" => path, "source_sha256" => snapshot.sha256))
    end
    workspace_source_checkpoint(sources.context)
    versions
end

function language_result_source!(sources::LanguageResultSources, uri)
    absolute, path = try
        language_workspace_uri(sources.context, uri)
    catch cause
        cause isa ShenScopeError || rethrow()
        cause.code in (:permission, :path, :language_uri) || rethrow()
        language_omit!(sources, cause.code == :path ? "missing_source" : "unavailable_workspace_uri")
        return nothing
    end
    haskey(sources.cache, path) && return sources.cache[path]
    if length(sources.cache) >= sources.maximum_files || sources.bytes >= sources.maximum_bytes
        language_omit!(sources, "source_capacity")
        return nothing
    end
    snapshot = read_workspace_snapshot(sources.context, path; maximum_bytes=2*1024^2,
        tool="language.source", unicode_line_separators=false)
    if sources.bytes + ncodeunits(snapshot.source.source) > sources.maximum_bytes
        language_omit!(sources, "source_capacity")
        return nothing
    end
    sources.bytes += ncodeunits(snapshot.source.source)
    sources.cache[path] = snapshot
    snapshot
end

function language_result_location(value, sources::LanguageResultSources; origin=nothing)
    value isa AbstractDict || throw(ShenScopeError(:language_protocol, "Language location must be an object"))
    linked = haskey(value, "targetUri")
    if linked
        haskey(value, "targetRange") && haskey(value, "targetSelectionRange") ||
            throw(ShenScopeError(:language_protocol, "Language location link lacks target ranges"))
        uri = value["targetUri"]
    else
        haskey(value, "uri") && haskey(value, "range") ||
            throw(ShenScopeError(:language_protocol, "Language location lacks a URI or range"))
        uri = value["uri"]
    end
    snapshot = language_result_source!(sources, uri)
    snapshot === nothing && return nothing
    location = language_range(snapshot.source, value[linked ? "targetSelectionRange" : "range"])
    result = Dict{String,Any}("path" => snapshot.path, "source_sha256" => snapshot.sha256,
        "location" => range_dict(location), "editor_range" => source_editor_range(snapshot.source, location))
    if linked
        target = language_range(snapshot.source, value["targetRange"])
        outer_first, outer_last = source_range_indices(snapshot.source, target)
        inner_first, inner_last = source_range_indices(snapshot.source, location)
        outer_first <= inner_first <= inner_last <= outer_last ||
            throw(ShenScopeError(:language_protocol, "Language location selection escapes its target range"))
        result["target_range"] = range_dict(target)
        if haskey(value, "originSelectionRange") && value["originSelectionRange"] !== nothing
            origin === nothing && throw(ShenScopeError(:language_protocol, "Location link has no verified origin source"))
            result["origin_range"] = range_dict(language_range(origin.source, value["originSelectionRange"]))
        end
    end
    result
end

function normalize_language_locations(value, sources::LanguageResultSources; maximum=1000, origin=nothing)
    rows = value === nothing ? Any[] : value isa AbstractVector ? value : Any[value]
    rows isa AbstractVector && length(rows) <= 16_384 ||
        throw(ShenScopeError(:language_protocol, "Language locations exceed input capacity"))
    selected = Dict{String,Any}[]
    identities = Set{String}()
    for (index, row) in enumerate(rows)
        workspace_source_checkpoint(sources.context)
        if length(selected) >= maximum
            language_omit!(sources, "result_capacity")
            continue
        end
        result = language_result_location(row, sources; origin)
        result === nothing && continue
        identity = digest(canonical(result))
        identity in identities && continue
        push!(identities, identity)
        result["id"] = identity
        push!(selected, result)
    end
    Dict("items" => selected, "reported_items" => length(rows), "omitted" => deepcopy(sources.omitted),
        "projection_truncated" => !isempty(sources.omitted), "column_unit" => "utf8_byte",
        "source_versions_verified" => true, "locations_are_server_reports" => true)
end
