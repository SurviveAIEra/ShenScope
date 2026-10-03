function prune_context_tools(messages::AbstractVector{Message}, original::AbstractVector{Message},
        first_original::Int, config::ContextConfig; recent_boundary=length(original) + 1)
    result = Message[]
    evidence = Dict{String,Any}[]
    for (offset, message) in enumerate(messages)
        index = first_original + offset - 1
        if message.role != :tool || index >= recent_boundary || ncodeunits(message.text) <= config.tool_preview_bytes
            push!(result, message); continue
        end
        reference = context_source_reference(original[index], index)
        value = try parsejson(message.text) catch; nothing end
        envelope = Dict{String,Any}("context_projection" => merge(reference,
            Dict("version" => 1, "truncated" => true, "recover" => "context.source")),
            "preview" => context_excerpt(message.text, max(64, config.tool_preview_bytes - 1024)))
        if value isa AbstractDict
            for key in ("ok", "error", "artifact_sha256")
                item = get(value, key, nothing)
                item isa Bool && (envelope[key] = item)
                item isa AbstractString && (envelope[key] = context_excerpt(item, 512))
            end
        end
        text = canonical(envelope)
        if ncodeunits(text) >= ncodeunits(message.text)
            push!(result, message); continue
        end
        push!(result, Message(:tool, text; call_id=message.call_id, native=deepcopy(message.native)))
        push!(evidence, merge(reference, Dict("projected_bytes" => ncodeunits(text))))
    end
    result, evidence
end
