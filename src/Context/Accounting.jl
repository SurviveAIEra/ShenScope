function context_measure(provider::AbstractModelProvider, request::ModelRequest, config::ContextConfig)
    capability = capabilities(provider)
    message_bytes = sum(ncodeunits(canonical(message_dict(message))) for message in request.messages; init=0)
    tools_bytes = ncodeunits(canonical(request.tools))
    options_bytes = ncodeunits(canonical(request.options))
    envelope_bytes = ncodeunits(canonical(Dict("messages" => message_dict.(request.messages),
        "tools" => request.tools, "options" => request.options, "max_output" => request.max_output)))
    # Measure the provider's actual serialization too: chat, Responses,
    # Anthropic, Gemini and Ollama do not have identical envelopes. Preparing
    # this body deliberately performs no credential lookup or network request.
    wire = provider isa HTTPProvider ? canonical(model_body(provider, request)) : canonical(Dict("messages" => message_dict.(request.messages),
        "tools" => request.tools, "options" => request.options, "max_output" => request.max_output))
    wire_bytes = ncodeunits(wire)
    estimate = max(estimate_request_tokens(request), estimate_text_tokens(wire) + 32)
    input_limit = max(0, capability.context_window - request.max_output - config.safety_tokens)
    ContextMeasure(message_bytes, tools_bytes, options_bytes, envelope_bytes, wire_bytes,
        estimate, request.max_output, capability.context_window, input_limit, config.max_request_bytes)
end

function measure_view(measure::ContextMeasure)
    Dict("message_bytes" => measure.message_bytes, "tools_bytes" => measure.tools_bytes,
        "options_bytes" => measure.options_bytes, "envelope_bytes" => measure.envelope_bytes,
        "wire_bytes" => measure.wire_bytes, "estimated_tokens" => measure.estimated_tokens,
        "token_source" => "byte_and_unicode_estimate", "max_output" => measure.max_output,
        "context_window" => measure.context_window, "input_limit" => measure.input_limit,
        "byte_limit" => measure.byte_limit, "fits" => context_fits(measure))
end

context_fits(measure::ContextMeasure) = measure.estimated_tokens <= measure.input_limit &&
    max(measure.envelope_bytes, measure.wire_bytes) <= measure.byte_limit

function context_require_capabilities(provider::AbstractModelProvider, request::ModelRequest)
    capability = capabilities(provider)
    request.max_output > 0 && request.max_output <= capability.max_output ||
        throw(ShenScopeError(:capability, "Requested output exceeds model limit"))
    !isempty(request.tools) && !capability.tools && throw(ShenScopeError(:capability, "Model does not support tools"))
    request.max_output < capability.context_window || throw(ShenScopeError(:context_overflow, "No input space remains after output reservation"))
end

function context_request(provider, system, messages, tools, max_output, options, config)
    request = ModelRequest(vcat([Message(:system, system)], messages), deepcopy(tools), max_output, deepcopy(options))
    context_require_capabilities(provider, request)
    request, context_measure(provider, request, config)
end
