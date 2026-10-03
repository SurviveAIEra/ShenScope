function context_groups(messages::AbstractVector{Message})
    groups = ContextGroup[]
    pending = Set{String}()
    known = Set{String}()
    answered = Set{String}()
    first_index = 1
    ids = String[]
    for (index, message) in enumerate(messages)
        message.role in (:system, :user, :assistant, :tool) || throw(ShenScopeError(:context_pairing, "Unknown transcript role"))
        !isempty(message.calls) && message.role != :assistant && throw(ShenScopeError(:context_pairing, "Only assistant messages may declare tool calls"))
        for call in message.calls
            !isempty(call.id) && !(call.id in known) || throw(ShenScopeError(:context_pairing, "Duplicate or empty transcript tool call ID"))
            push!(known, call.id); push!(pending, call.id); push!(ids, call.id)
        end
        if message.role == :tool
            message.call_id !== nothing && message.call_id in pending && !(message.call_id in answered) ||
                throw(ShenScopeError(:context_pairing, "Orphan or duplicate transcript tool result"))
            delete!(pending, message.call_id); push!(answered, message.call_id)
        elseif message.call_id !== nothing
            throw(ShenScopeError(:context_pairing, "A transcript result identity requires the tool role"))
        end
        if isempty(pending)
            push!(groups, ContextGroup(first_index, index, true, copy(ids)))
            first_index = index + 1; empty!(ids)
        end
    end
    first_index <= length(messages) && push!(groups, ContextGroup(first_index, length(messages), false, copy(ids)))
    groups
end

function context_recent_boundary(messages::AbstractVector{Message}, groups::Vector{ContextGroup}, recent::Int)
    isempty(messages) && return 1
    boundary = max(1, length(messages) - recent + 1)
    for group in groups
        if group.first <= boundary <= group.last
            return group.first
        end
    end
    throw(ShenScopeError(:context_pairing, "Unable to select a balanced recent context"))
end

function context_prefix_digest(messages::AbstractVector{Message}, through::Int)
    0 <= through <= length(messages) || throw(ShenScopeError(:context_checkpoint, "Invalid checkpoint boundary"))
    hash = digest("ShenScope transcript prefix v1")
    for index in 1:through
        hash = digest(hash * ":" * string(index) * ":" * canonical(message_dict(messages[index])))
    end
    hash
end

function context_source_reference(message::Message, index::Int)
    Dict{String,Any}("message" => index, "role" => String(message.role),
        "sha256" => digest(canonical(message_dict(message))), "bytes" => ncodeunits(message.text),
        "call_id" => message.call_id, "tool_names" => [call.name for call in message.calls])
end
