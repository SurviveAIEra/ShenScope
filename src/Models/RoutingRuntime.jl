function model_route_fallback(route::ModelRoleRoute,error::ShenScopeError,delivered::Bool)
    !delivered && error.retryable && error.code in route.fallback_codes
end

model_route_error_code(error::ShenScopeError) = occursin(r"^[a-z][a-z0-9_]{0,63}$",String(error.code)) ? String(error.code) : "extension"

function prepare_model_route(plan::ModelRoutePlan)
    sum(candidate.wire_bytes for candidate in plan.candidates;init=0) <= 16*1024^2 ||
        throw(ShenScopeError(:capacity,"Combined model route wire bodies exceed capacity"))
    # Every eligible credential is captured before the first network approval.
    # Ineligible sources never trigger credential lookup.
    [(candidate,prepare_request(candidate.provider,candidate.request)) for candidate in plan.candidates]
end

function stream_chat(provider::RoutedProvider,request::ModelRequest,sink::Function,ctx::RuntimeContext)
    model_route_checkpoint(ctx)
    fleet = provider.fleet;route = fleet.roles[provider.role]
    id = begin_model_route!(fleet,ctx)
    delivered = Ref(false);attempts = Dict{String,Any}[]
    receipt = Dict{String,Any}("id"=>id,"role"=>provider.role,"routing_revision"=>fleet.revision,
        "request_sha256"=>nothing,"started_at"=>utcstamp(),"attempts"=>attempts,
        "outcome"=>"interrupted","selected_profile"=>nothing,"delivered"=>false,"code"=>nothing)
    guarded = (kind,payload)->begin
        kind in (:text_delta,:usage,:tool_call,:model_progress) && (delivered[] = true)
        try
            sink(kind,payload)
        catch cause
            cause isa ShenScopeError && rethrow()
            throw(ShenScopeError(:delivery,"Model route output consumer failed"))
        end
    end
    try
        plan = model_route_plan(provider,request)
        receipt["request_sha256"] = plan.request_sha256
        isempty(plan.candidates) && throw(ShenScopeError(:route_ineligible,"No configured model profile can accept this request"))
        prepared = prepare_model_route(plan)
        model_route_checkpoint(ctx)
        for (position,(candidate,wire)) in enumerate(prepared)
            model_route_checkpoint(ctx)
            receipt["selected_profile"] = candidate.profile_id
            observation = Dict{String,Any}("profile"=>candidate.profile_id,"provider"=>candidate.provider_id,
                "model"=>candidate.provider.config.model,"source_id"=>catalog_source_id(candidate.provider),
                "position"=>position,"outcome"=>"started","code"=>nothing)
            push!(attempts,observation)
            model_policy_event!(ctx,:model_route_selected,merge(copy(observation),Dict("id"=>id,
                "role"=>plan.role,"routing_revision"=>plan.revision,"request_sha256"=>plan.request_sha256)))
            try
                result = stream_prepared_chat(candidate.provider,wire,guarded,ctx)
                model_route_checkpoint(ctx)
                observation["outcome"] = "success";receipt["outcome"] = "success"
                native = deepcopy(result.message.native)
                native["route"] = Dict("role"=>plan.role,"profile"=>candidate.profile_id,"provider"=>candidate.provider_id,
                    "routing_revision"=>plan.revision,"request_id"=>id)
                message = Message(result.message.role,result.message.text;calls=result.message.calls,
                    call_id=result.message.call_id,native)
                return ModelResponse(message,result.usage,result.finish)
            catch cause
                model_route_checkpoint(ctx)
                error = cause isa ShenScopeError ? cause : model_attempt_failure(cause).error
                observation["outcome"] = "failed";observation["code"] = model_route_error_code(error)
                if position == length(prepared) || !model_route_fallback(route,error,delivered[])
                    throw(error)
                end
                model_policy_event!(ctx,:model_route_fallback,Dict("id"=>id,"role"=>plan.role,
                    "from_profile"=>candidate.profile_id,"to_profile"=>prepared[position+1][1].profile_id,
                    "code"=>String(error.code),"delivery_started"=>false))
            end
        end
        throw(ShenScopeError(:runtime,"Model route produced no result"))
    catch cause
        receipt["outcome"] = "failed"
        receipt["code"] = cause isa ShenScopeError ? model_route_error_code(cause) : "internal"
        if !isempty(attempts) && last(attempts)["outcome"] == "started"
            last(attempts)["outcome"] = "failed";last(attempts)["code"] = receipt["code"]
        end
        rethrow()
    finally
        receipt["delivered"] = delivered[];receipt["completed_at"] = utcstamp()
        finish_model_route!(fleet,id,ctx,receipt)
    end
end
