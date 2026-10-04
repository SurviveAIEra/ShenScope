function model_route_request_snapshot(request::ModelRequest)
    length(request.messages) <= 2048 && length(request.tools) <= 128 ||
        throw(ShenScopeError(:capacity,"Model route input exceeds message/schema capacity"))
    request.max_output > 0 || throw(ShenScopeError(:arguments,"Model route output limit must be positive"))
    document = Dict("messages"=>message_dict.(request.messages),"tools"=>request.tools,
        "max_output"=>request.max_output,"options"=>request.options)
    encoded = bounded_canonical_json(document;maximum=8*1024^2,max_depth=24,max_nodes=100_000)
    deepcopy(request),digest(encoded)
end

function model_route_profile_request(profile::ModelProfile,request::ModelRequest)
    options = parsejson(profile.selection.options_json)
    merge!(options,deepcopy(request.options))
    ModelRequest(request.messages,request.tools,request.max_output,options)
end

function model_route_replay_reason(provider::HTTPProvider,request::ModelRequest)
    identity = model_wire_identity(provider.config)
    source = catalog_source_id(provider)
    for message in request.messages
        replay = false
        for field in MODEL_ROUTE_NATIVE_FIELDS
            haskey(message.native,field) || continue
            value = message.native[field]
            (field == "reasoning_content" ? value isa String : value isa AbstractVector) || return :native_replay_invalid
            replay |= !isempty(value)
        end
        replay || continue
        get(message.native,"identity",nothing) == identity || return :native_replay_model_mismatch
        recorded_source = get(message.native,"source_id",nothing)
        recorded_source === nothing && return :native_replay_scope_unknown
        recorded_source == source || return :native_replay_source_mismatch
    end
    nothing
end

function model_route_require_features(provider::HTTPProvider,request::ModelRequest)
    capability = capabilities(provider)
    capability.streaming || throw(ShenScopeError(:capability,"Model profile does not declare streaming support"))
    for field in ("response_format","format")
        haskey(request.options,field) && !capability.structured_output &&
            throw(ShenScopeError(:capability,"Model profile does not declare structured output support"))
    end
    for field in ("reasoning","reasoning_effort","thinking")
        value = get(request.options,field,nothing)
        value === nothing || value === false || value in ("off","none","disabled") || capability.reasoning ||
            throw(ShenScopeError(:capability,"Model profile does not declare reasoning support"))
    end
    nothing
end

function model_route_plan(provider::RoutedProvider,request::ModelRequest)
    fleet = provider.fleet
    lock(fleet.mutex) do;fleet.closed && throw(ShenScopeError(:runtime,"Model routing runtime is closed"));end
    frozen,request_hash = model_route_request_snapshot(request)
    candidates = ModelRouteCandidate[];excluded = Dict{String,Any}[]
    for id in fleet.roles[provider.role].profiles
        profile = fleet.profiles[id];wire = route_profile_provider(fleet,profile)
        candidate_request = model_route_profile_request(profile,frozen)
        reason = model_route_replay_reason(wire,candidate_request)
        bytes = 0;estimated = 0
        if reason === nothing
            try
                model_route_require_features(wire,candidate_request)
                validate_request(wire,candidate_request)
                encoded = bounded_canonical_json(model_body(wire,candidate_request);
                    maximum=8*1024^2,max_depth=24,max_nodes=100_000)
                bytes = ncodeunits(encoded)
                estimated = max(estimate_request_tokens(candidate_request),estimate_text_tokens(encoded)+32)
                estimated+candidate_request.max_output <= capabilities(wire).context_window ||
                    throw(ShenScopeError(:context_overflow,"Model route wire envelope exceeds profile capacity"))
            catch error
                error isa ShenScopeError || rethrow()
                reason = error.code
            end
        end
        if reason === nothing
            push!(candidates,ModelRouteCandidate(id,profile.selection.provider_id,wire,candidate_request,bytes,estimated))
        else
            push!(excluded,Dict("profile"=>id,"provider"=>profile.selection.provider_id,"code"=>String(reason)))
        end
    end
    ModelRoutePlan(provider.role,fleet.revision,request_hash,candidates,excluded)
end

function model_route_plan_dict(plan::ModelRoutePlan)
    Dict("role"=>plan.role,"routing_revision"=>plan.revision,"request_sha256"=>plan.request_sha256,
        "eligible"=>[Dict("profile"=>candidate.profile_id,"provider"=>candidate.provider_id,
            "model"=>candidate.provider.config.model,"source_id"=>catalog_source_id(candidate.provider),
            "wire_bytes"=>candidate.wire_bytes,"estimated_input_tokens"=>candidate.estimated_tokens,
            "token_source"=>"byte_and_unicode_estimate") for candidate in plan.candidates],
        "excluded"=>deepcopy(plan.excluded),"credential_lookup_performed"=>false,"network_request_performed"=>false,
        "eligibility_is_availability_proof"=>false)
end

function validate_request(provider::RoutedProvider,request::ModelRequest)
    isempty(model_route_plan(provider,request).candidates) &&
        throw(ShenScopeError(:route_ineligible,"No configured model profile can accept this request"))
    nothing
end
