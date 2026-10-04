function model_request_from_dict(value::AbstractDict)
    encoded = bounded_canonical_json(value;maximum=8*1024^2,max_depth=24,max_nodes=100_000)
    document = bounded_json_object(encoded;maximum=8*1024^2,max_depth=24,max_nodes=100_000,error_code=:arguments)
    all(key -> key in ("messages","tools","max_output","options"),keys(document)) || throw(ShenScopeError(:arguments,"Unknown token-count request field"))
    entries = get(document,"messages",nothing)
    entries isa AbstractVector && length(entries) <= 2048 || throw(ShenScopeError(:arguments,"Token-count messages must be a bounded array"))
    messages = Message[]
    for entry in entries
        entry isa AbstractDict && Set(keys(entry)) <= Set(["role","text","calls","call_id","native"]) ||
            throw(ShenScopeError(:arguments,"Invalid token-count message"))
        role = get(entry,"role",nothing)
        role in ("system","user","assistant","tool") || throw(ShenScopeError(:arguments,"Invalid token-count message role"))
        text = get(entry,"text","")
        text isa AbstractString || throw(ShenScopeError(:arguments,"Token-count message text must be a string"))
        native = get(entry,"native",Dict())
        native isa AbstractDict || throw(ShenScopeError(:arguments,"Token-count native metadata must be an object"))
        call_id = get(entry,"call_id",nothing)
        call_id === nothing || call_id isa AbstractString && 1 <= ncodeunits(call_id) <= 512 || throw(ShenScopeError(:arguments,"Invalid tool result call ID"))
        role == "tool" && call_id === nothing && throw(ShenScopeError(:arguments,"Tool results require a call ID"))
        calls = get(entry,"calls",Any[])
        calls isa AbstractVector && length(calls) <= 128 || throw(ShenScopeError(:arguments,"Invalid token-count tool calls"))
        parsed = ToolCall[]
        for call in calls
            call isa AbstractDict && Set(keys(call)) == Set(["id","name","arguments"]) && call["arguments"] isa AbstractDict ||
                throw(ShenScopeError(:arguments,"Invalid token-count tool call"))
            id = catalog_identifier(call["id"];field="tool call ID");name = catalog_identifier(call["name"];maximum=128,field="tool name")
            push!(parsed,ToolCall(id,name,Dict{String,Any}(call["arguments"])))
        end
        isempty(parsed) || role == "assistant" || throw(ShenScopeError(:arguments,"Only assistant messages contain tool calls"))
        push!(messages,Message(Symbol(role),text;calls=parsed,call_id,native))
    end
    tools = get(document,"tools",Any[])
    tools isa AbstractVector && length(tools) <= 128 || throw(ShenScopeError(:arguments,"Token-count tools must be a bounded array"))
    schemas = Dict{String,Any}[];names = Set{String}()
    for tool in tools
        tool isa AbstractDict && Set(keys(tool)) <= Set(["name","description","parameters"]) &&
            haskey(tool,"name") && get(tool,"parameters",nothing) isa AbstractDict || throw(ShenScopeError(:arguments,"Invalid token-count tool schema"))
        name = catalog_identifier(tool["name"];maximum=128,field="tool name")
        name in names && throw(ShenScopeError(:arguments,"Duplicate token-count tool name"))
        get(tool,"description","") isa AbstractString || throw(ShenScopeError(:arguments,"Tool description must be a string"))
        push!(names,name);push!(schemas,Dict{String,Any}(tool))
    end
    maximum = get(document,"max_output",1024)
    maximum isa Integer && !(maximum isa Bool) && 1 <= maximum <= 4_000_000 || throw(ShenScopeError(:arguments,"Invalid requested output capacity"))
    options = get(document,"options",Dict())
    options isa AbstractDict || throw(ShenScopeError(:arguments,"Token-count options must be an object"))
    ModelRequest(messages,schemas,Int(maximum),Dict{String,Any}(options))
end

function model_input_projection(provider::HTTPProvider,request::ModelRequest)
    body = prepare_request(provider,request;accounting=true).body
    fields = Set(["messages","input","contents","system","systemInstruction","tools","cachedContent"])
    Dict{String,Any}(field=>value for (field,value) in body if field in fields)
end

function model_token_estimate(provider::HTTPProvider,request::ModelRequest)
    projection = model_input_projection(provider,request)
    projection_encoded = bounded_canonical_json(projection)
    components = Dict{String,Int}()
    for (field,value) in projection
        encoded = bounded_canonical_json(value;maximum=8*1024^2)
        components[field] = estimate_text_tokens(encoded)
    end
    input = sum(values(components);init=0)+32
    Dict("input_tokens"=>input,"components"=>components,"overhead_estimate"=>32,"source"=>"estimate",
        "method"=>"UTF-8 JSON byte heuristic with CJK/emoji supplements","tokenizer_verified"=>false,
        "projection_sha256"=>digest(projection_encoded),
        "limitations"=>["This is an estimate of assembled input fields, not a model tokenizer or billed usage.",
            "Opaque provider replay is measured as JSON bytes by this heuristic."])
end

function model_count_report(provider::HTTPProvider,request::ModelRequest,measurement::AbstractDict)
    capability = capabilities(provider);input = measurement["input_tokens"]
    violations = String[]
    input+request.max_output <= capability.context_window || push!(violations,"Input plus requested output exceeds configured context capacity")
    request.max_output <= capability.max_output || push!(violations,"Requested output exceeds configured output capacity")
    isempty(request.tools) || capability.tools || push!(violations,"Configured model does not support tool calls")
    merge(Dict{String,Any}(measurement),Dict("source_id"=>catalog_source_id(provider),"model"=>provider.config.model,
        "protocol"=>String(provider.config.protocol),"requested_output"=>request.max_output,
        "configured_context_window"=>capability.context_window,"configured_max_output"=>capability.max_output,
        "within_configured_capacity"=>isempty(violations),"capacity_violations"=>violations,
        "count_is_inference_usage"=>false,"counted_at"=>utcstamp()))
end

function count_model_tokens(provider::HTTPProvider,request::ModelRequest,ctx::RuntimeContext;mode=:auto)
    mode in (:auto,:estimate,:provider) || throw(ShenScopeError(:arguments,"Unknown model token-count mode"))
    authorize!(ctx,:read,"models.count",ctx.root;reason="Measure explicit assembled model request input")
    check_cancelled(ctx.cancellation)
    snapshot = deepcopy(request)
    # Validate bounded JSON before network I/O, without rejecting an oversized
    # context that the caller is trying to measure for compaction planning.
    projection = model_input_projection(provider,snapshot)
    projection_hash = digest(bounded_canonical_json(projection))
    if mode == :estimate || !(provider.config.protocol in (:anthropic,:gemini))
        mode == :provider && throw(ShenScopeError(:capability,"This protocol has no implemented provider token-count endpoint"))
        report = model_count_report(provider,snapshot,model_token_estimate(provider,snapshot))
        check_cancelled(ctx.cancellation)
        lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
        permission_decision(ctx.permissions,PermissionRequest("model-count-current",:read,"models.count",ctx.root,"Publish model token estimate")) != Deny ||
            throw(ShenScopeError(:permission,"Model count read permission was revoked"))
        mode == :auto && (report["fallback_reason"] = "No implemented token-count endpoint for this protocol")
        return report
    end
    key = CredentialSnapshot(provider.credential_lookup(provider.config.key_env))
    prepared = model_service_request(provider,key,"count_tokens";request=snapshot)
    response = try
        model_service_json(provider,prepared,ctx;max_bytes=64*1024)
    catch cause
        if mode == :auto && cause isa ShenScopeError && cause.code == :request && cause.message == "Model endpoint returned HTTP 404"
            report = model_count_report(provider,snapshot,model_token_estimate(provider,snapshot))
            report["fallback_reason"] = "Provider token-count endpoint returned HTTP 404"
            return report
        end
        rethrow()
    end
    field = provider.config.protocol == :anthropic ? "input_tokens" : "totalTokens"
    value = get(response.data,field,nothing)
    value isa Integer && !(value isa Bool) && 0 <= value <= 4_000_000 || throw(ShenScopeError(:protocol,"Invalid provider token count"))
    permission_decision(ctx.permissions,PermissionRequest("model-count-current",:read,"models.count",ctx.root,"Publish model token count")) != Deny ||
        throw(ShenScopeError(:permission,"Model count read permission was revoked"))
    report = model_count_report(provider,snapshot,Dict("input_tokens"=>Int(value),"source"=>"provider_api",
        "method"=>provider.config.protocol == :anthropic ? "messages/count_tokens" : "models/countTokens",
        "projection_sha256"=>projection_hash,"request_sha256"=>digest(prepared.body),"tokenizer_verified"=>false,
        "limitations"=>["Provider-reported count describes this projected request; it is not billed inference usage."]))
    emit!(ctx,:model_tokens_counted,Dict("model"=>provider.config.model,"input_tokens"=>Int(value),"source"=>"provider_api"))
    report
end
