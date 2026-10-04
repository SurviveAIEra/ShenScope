struct ModelServiceRequest
    method::String
    endpoint::String
    headers::Vector{Pair{String,String}}
    body::Union{Nothing,String}
    source_id::String
    operation::String
    credentials::CredentialSnapshot
end
Base.show(io::IO,request::ModelServiceRequest) = print(io,"ModelServiceRequest(",request.operation,", ",request.source_id,")")

struct ModelServiceAuthorization
    source_id::String
    host::String
    method::String
    operation::String
    scope::Tuple{String,String,String}
    cancellation::CancellationToken
end

function authorize_model_service!(provider::HTTPProvider,request::ModelServiceRequest,ctx::RuntimeContext)
    catalog_source_id(provider) == request.source_id || throw(ShenScopeError(:conflict,"Model service source changed"))
    host = String(validate_endpoint(request.endpoint).host)
    authorize!(ctx,:network,provider_name(provider),host;reason="Model "*request.operation*" API request")
    model_service_checkpoint(ctx,provider,request)
    ModelServiceAuthorization(request.source_id,host,request.method,request.operation,operation_scope(ctx),ctx.cancellation)
end

function model_service_authorization_check(grant::ModelServiceAuthorization,request::ModelServiceRequest,ctx::RuntimeContext)
    grant.source_id == request.source_id && grant.host == String(HTTP.URI(request.endpoint).host) &&
        grant.method == request.method && grant.operation == request.operation &&
        grant.scope == operation_scope(ctx) && grant.cancellation === ctx.cancellation ||
        throw(ShenScopeError(:permission,"Model service authorization belongs to another operation or scope"))
    nothing
end

function model_service_headers(provider::HTTPProvider,key::CredentialSnapshot)
    headers = Pair{String,String}["Accept"=>"application/json"]
    if provider.config.protocol == :anthropic
        push!(headers,"anthropic-version"=>"2023-06-01")
        isempty(key.value) || push!(headers,"x-api-key"=>key.value)
    elseif provider.config.protocol == :gemini
        isempty(key.value) || push!(headers,"x-goog-api-key"=>key.value)
    else
        isempty(key.value) || push!(headers,"Authorization"=>"Bearer "*key.value)
    end
    headers
end

function model_service_request(provider::HTTPProvider,key::CredentialSnapshot,operation::String;
        cursor=nothing,etag=nothing,request=nothing)
    source = catalog_source_id(provider)
    config = provider.config
    endpoint = rstrip(config.endpoint,'/')
    headers = model_service_headers(provider,key)
    body = nothing;method = "GET"
    if operation == "catalog"
        if config.protocol == :ollama
            cursor === nothing || throw(ShenScopeError(:protocol,"Ollama catalog does not support pagination"))
            endpoint *= "/api/tags"
        else
            endpoint *= "/models"
            if config.protocol == :anthropic
                endpoint *= "?limit=100"
                cursor === nothing || (endpoint *= "&after_id="*HTTP.escapeuri(cursor))
            elseif config.protocol == :gemini
                endpoint *= "?pageSize=100"
                cursor === nothing || (endpoint *= "&pageToken="*HTTP.escapeuri(cursor))
            elseif cursor !== nothing
                endpoint *= "?after="*HTTP.escapeuri(cursor)
            end
        end
        etag === nothing || push!(headers,"If-None-Match"=>etag)
    elseif operation == "count_tokens"
        request isa ModelRequest || throw(ShenScopeError(:arguments,"Token counting requires an assembled request"))
        prepared = prepare_request(provider,request;accounting=true)
        # Body construction reads no credentials. Headers use the captured key.
        if config.protocol == :anthropic
            endpoint *= "/messages/count_tokens"
            fields = Set(["model","messages","system","tools","tool_choice","thinking"])
            body = bounded_canonical_json(Dict(name=>value for (name,value) in prepared.body if name in fields))
        elseif config.protocol == :gemini
            occursin(r"^[A-Za-z0-9_.-]+$",config.model) || throw(ShenScopeError(:config,"Invalid Gemini model ID"))
            endpoint *= "/models/"*config.model*":countTokens"
            generated = merge(prepared.body,Dict("model"=>"models/"*config.model))
            body = bounded_canonical_json(Dict("generateContentRequest"=>generated))
        else
            throw(ShenScopeError(:capability,"This provider protocol has no implemented token-count endpoint"))
        end
        ncodeunits(body) <= 8*1024^2 || throw(ShenScopeError(:capacity,"Token-count request exceeds capacity"))
        push!(headers,"Content-Type"=>"application/json");method = "POST"
    else
        throw(ShenScopeError(:arguments,"Unknown model service operation"))
    end
    ModelServiceRequest(method,endpoint,headers,body,source,operation,key)
end

function model_service_checkpoint(ctx::RuntimeContext,provider::HTTPProvider,request::ModelServiceRequest)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    host = String(HTTP.URI(request.endpoint).host)
    permission_decision(ctx.permissions,PermissionRequest("model-service-current",:network,
        provider_name(provider),host,"Continue model service request")) != Deny ||
        throw(ShenScopeError(:permission,"Model service network permission was revoked"))
    nothing
end
