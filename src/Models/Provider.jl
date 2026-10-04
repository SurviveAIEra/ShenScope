provider_name(p::AbstractModelProvider) = string(nameof(typeof(p)))
capabilities(::AbstractModelProvider) = ModelCapabilities()

Base.@kwdef struct ProviderConfig
    protocol::Symbol = :openai_chat
    name::String = "openai-compatible"
    endpoint::String = "https://api.openai.com/v1"
    model::String = "gpt-4.1"
    key_env::String = "SHENSCOPE_MODEL_KEY"
    timeout::Float64 = 120.0
    retries::Int = 2
    input_price::Float64 = 0.0
    output_price::Float64 = 0.0
    capabilities::ModelCapabilities = ModelCapabilities()
end

struct HTTPProvider <: AbstractModelProvider
    config::ProviderConfig
    credential_lookup::Function
    runtime::ModelProviderRuntime
end
function HTTPProvider(config::ProviderConfig,credential_lookup::Function;
        runtime=ModelProviderRuntime(;retry_policy=ModelRetryPolicy(;max_retries=config.retries)))
    HTTPProvider(validate_config(config),credential_lookup,runtime)
end
HTTPProvider(config::ProviderConfig;kwargs...) = HTTPProvider(config,key->get(ENV,key,"");kwargs...)
Base.show(io::IO,provider::HTTPProvider) = print(io,"HTTPProvider(",repr(provider.config.name),", ",repr(provider.config.model),")")
provider_name(p::HTTPProvider) = p.config.name
capabilities(p::HTTPProvider) = p.config.capabilities

struct CredentialSnapshot
    value::String
end
Base.show(io::IO, s::CredentialSnapshot) = print(io,"CredentialSnapshot(",isempty(s.value) ? "unconfigured" : "configured",")")

struct PreparedRequest
    endpoint::String
    headers::Vector{Pair{String,String}}
    body::Dict{String,Any}
    protocol::Symbol
    identity::String
    credentials::CredentialSnapshot
end
Base.show(io::IO,r::PreparedRequest) = print(io,"PreparedRequest(",r.protocol,", ",r.identity,")")

function validate_endpoint(endpoint::String)
    uri = HTTP.URI(endpoint)
    (!isempty(uri.userinfo) || !isempty(uri.fragment)) &&
        throw(ShenScopeError(:config,"Endpoint may not contain credentials or a fragment"))
    local_host = uri.host in ("localhost","127.0.0.1","[::1]","::1")
    (uri.scheme=="https" || (uri.scheme=="http" && local_host)) ||
        throw(ShenScopeError(:config,"Endpoint must use HTTPS, except loopback development servers"))
    isempty(uri.host) && throw(ShenScopeError(:config,"Endpoint host missing"))
    return uri
end

function validate_config(c::ProviderConfig)
    c.protocol in (:openai_chat,:openai_responses,:anthropic,:gemini,:ollama) ||
        throw(ShenScopeError(:config,"Unsupported model protocol"))
    uri = validate_endpoint(c.endpoint)
    isempty(uri.query) || throw(ShenScopeError(:config,"Provider base URL cannot contain a query"))
    isempty(c.model) && throw(ShenScopeError(:config,"Model missing"))
    isfinite(c.timeout) && c.timeout>0 && 0 <= c.retries <= 32 && isfinite(c.input_price) &&
        isfinite(c.output_price) && c.input_price>=0 && c.output_price>=0 ||
        throw(ShenScopeError(:config,"Invalid provider limits or prices"))
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$",c.key_env) || throw(ShenScopeError(:config,"Invalid key variable name"))
    1 <= c.capabilities.max_output < c.capabilities.context_window <= 4_000_000 ||
        throw(ShenScopeError(:config, "Invalid model context or output capacity"))
    return c
end

function estimate_text_tokens(text::AbstractString)
    supplement = 0
    for character in text
        code = UInt32(character)
        if 0x3040 <= code <= 0x30ff || 0x3400 <= code <= 0x9fff || 0xac00 <= code <= 0xd7af ||
                0xf900 <= code <= 0xfaff || 0x20000 <= code <= 0x3134f
            supplement += 1
        elseif 0x1f000 <= code <= 0x1faff
            supplement += 2
        end
    end
    cld(ncodeunits(text), 3) + supplement
end

function estimate_request_tokens(request::ModelRequest)
    tokens = sum(estimate_text_tokens(canonical(message_dict(message))) for message in request.messages; init=0)
    tokens += estimate_text_tokens(canonical(request.tools)) + estimate_text_tokens(canonical(request.options))
    tokens + 32
end

function validate_request(provider::AbstractModelProvider, request::ModelRequest)
    c = capabilities(provider)
    request.max_output>0 && request.max_output<=c.max_output ||
        throw(ShenScopeError(:capability,"Requested output exceeds model limit"))
    !isempty(request.tools) && !c.tools && throw(ShenScopeError(:capability,"Model does not support tools"))
    estimate_request_tokens(request)+request.max_output <= c.context_window ||
        throw(ShenScopeError(:context_overflow,"Assembled request exceeds model context window"))
end

mutable struct MockProvider <: AbstractModelProvider
    script::Vector{Any}
    cursor::Int
    delay::Float64
    requests::Vector{ModelRequest}
end
MockProvider(script::Vector;delay=0.0) = MockProvider(script,0,Float64(delay),ModelRequest[])
provider_name(::MockProvider) = "mock"
function stream_chat(p::MockProvider,request::ModelRequest,sink::Function,ctx::RuntimeContext)
    validate_request(p,request)
    check_cancelled(ctx.cancellation)
    push!(p.requests,deepcopy(request))
    p.cursor += 1
    p.cursor<=length(p.script) || throw(ShenScopeError(:mock,"Mock script exhausted"))
    action=p.script[p.cursor]
    action isa Exception && throw(action)
    action isa Function && (action=action(request))
    action isa ModelResponse || throw(ShenScopeError(:mock,"Mock script must return ModelResponse"))
    for ch in action.message.text
        cancellable_wait(ctx.cancellation,p.delay)
        sink(:text_delta,string(ch))
    end
    for call in action.message.calls
        check_cancelled(ctx.cancellation)
        sink(:tool_call,call)
    end
    sink(:usage,action.usage)
    return action
end

function response(text::AbstractString="";calls=ToolCall[],usage=Usage(),finish=isempty(calls) ? :stop : :tools,native=Dict{String,Any}())
    ModelResponse(Message(:assistant,text;calls,native),usage,finish)
end
