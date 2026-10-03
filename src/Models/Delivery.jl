mutable struct ModelDelivery
    text::IOBuffer
    usage::Union{Nothing,Usage}
    calls::Vector{ToolCall}
    channels::Set{Symbol}
    delivered::Bool
end
ModelDelivery() = ModelDelivery(IOBuffer(), nothing, ToolCall[], Set{Symbol}(), false)

function model_delivery_sink(delivery::ModelDelivery, ctx::RuntimeContext)
    (kind, payload) -> begin
        if kind == :text_delta
            delivery.delivered = true; push!(delivery.channels, :text)
            write(delivery.text, payload)
            emit!(ctx, kind, Dict("text" => payload))
        elseif kind == :usage
            delivery.delivered = true; push!(delivery.channels, :usage); delivery.usage = payload
            emit!(ctx, :usage, Dict("input_tokens" => payload.input_tokens, "output_tokens" => payload.output_tokens))
        elseif kind == :tool_call
            delivery.delivered = true; push!(delivery.channels, :tool)
            push!(delivery.calls, payload)
            emit!(ctx, kind, Dict("id" => payload.id, "name" => payload.name, "arguments" => payload.arguments))
        elseif kind == :model_progress
            delivery.delivered = true; push!(delivery.channels, :native_progress)
            emit!(ctx, kind, payload)
        else
            emit!(ctx, kind, Dict("text" => payload))
        end
    end
end

function record_interrupted_model!(session::Session, delivery::ModelDelivery, error)
    delivery.delivered || return nothing
    text = String(take!(delivery.text))
    known = Set(call.id for message in session.messages for call in message.calls)
    calls = ToolCall[]
    for call in delivery.calls
        call.id in known && continue
        push!(known, call.id); push!(calls, call)
    end
    native = Dict{String,Any}("interrupted" => true, "tools_dispatched" => false,
        "delivery_channels" => sort!(String.(collect(delivery.channels))),
        "error_code" => error isa ShenScopeError ? String(error.code) : "internal")
    add_message!(session, Message(:assistant, text; calls, native))
end
