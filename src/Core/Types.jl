abstract type AbstractModelProvider end
abstract type AbstractTool end
abstract type AbstractSandbox end
abstract type AbstractProjectDataBackend end
abstract type AbstractAnalyzer end
abstract type AbstractContextStrategy end
abstract type AbstractScheduler end

struct ShenScopeError <: Exception
    code::Symbol
    message::String
    retryable::Bool
end
ShenScopeError(code::Symbol, message::AbstractString) = ShenScopeError(code, String(message), false)
Base.showerror(io::IO, e::ShenScopeError) = print(io, e.code, ": ", e.message)

struct ToolCall
    id::String
    name::String
    arguments::Dict{String,Any}
end
ToolCall(name::AbstractString, arguments::AbstractDict) =
    ToolCall(string(uuid4()), String(name), Dict{String,Any}(arguments))

struct ToolResult
    id::String
    ok::Bool
    value::Any
    error::Union{Nothing,String}
end

struct Message
    role::Symbol
    text::String
    calls::Vector{ToolCall}
    call_id::Union{Nothing,String}
    native::Dict{String,Any}
end
Message(role::Symbol, text::AbstractString; calls=ToolCall[], call_id=nothing, native=Dict{String,Any}()) =
    Message(role, String(text), calls, call_id, Dict{String,Any}(native))

Base.@kwdef struct ModelCapabilities
    streaming::Bool = true
    tools::Bool = true
    parallel_tools::Bool = true
    vision::Bool = false
    reasoning::Bool = false
    structured_output::Bool = false
    prompt_cache::Bool = false
    context_window::Int = 128_000
    max_output::Int = 8_192
end

Base.@kwdef struct Usage
    input_tokens::Int = 0
    output_tokens::Int = 0
    cached_tokens::Int = 0
    cost::Float64 = 0.0
    source::Symbol = :reported
end

struct ModelResponse
    message::Message
    usage::Usage
    finish::Symbol
end

struct ModelRequest
    messages::Vector{Message}
    tools::Vector{Dict{String,Any}}
    max_output::Int
    options::Dict{String,Any}
end

struct AgentEvent
    sequence::Int
    kind::Symbol
    session_id::String
    trace_id::String
    timestamp::String
    payload::Any
end

utcstamp() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"
plain(x::JSON3.Object) = Dict{String,Any}(String(k) => plain(v) for (k,v) in pairs(x))
plain(x::JSON3.Array) = Any[plain(v) for v in x]
plain(x) = x
parsejson(s::AbstractString) = plain(JSON3.read(codeunits(s)))
parsejson(s::AbstractVector{UInt8}) = plain(JSON3.read(s))
parsejson(s::IO) = parsejson(read(s))

function canonical(x)
    if x isa AbstractDict
        return "{" * join((JSON3.write(String(k)) * ":" * canonical(x[k])
            for k in sort!(collect(keys(x)); by=string)), ",") * "}"
    elseif x isa AbstractVector || x isa Tuple
        return "[" * join(canonical.(x), ",") * "]"
    elseif x isa AbstractFloat
        isfinite(x) || throw(ShenScopeError(:protocol,"Non-finite JSON number"))
        # JSON parsers may read 0.0 as integer 0. The checksum representation
        # must survive that round trip, including negative zero.
        isinteger(x) && -2.0^63<=x<2.0^63 && return string(Int64(x))
    end
    return JSON3.write(x)
end
digest(x::AbstractString) = bytes2hex(sha256(x))

function message_dict(m::Message)
    return Dict("role"=>String(m.role), "text"=>m.text, "call_id"=>m.call_id,
        "calls"=>[Dict("id"=>c.id,"name"=>c.name,"arguments"=>c.arguments) for c in m.calls],
        "native"=>m.native)
end
function message_from_dict(d::AbstractDict)
    calls = ToolCall[ToolCall(c["id"], c["name"], Dict{String,Any}(c["arguments"]))
        for c in get(d, "calls", [])]
    return Message(Symbol(d["role"]), d["text"]; calls, call_id=get(d,"call_id",nothing),
        native=get(d,"native",Dict{String,Any}()))
end

function cliptext(text::AbstractString, limit::Int)
    limit >= 64 || throw(ArgumentError("text limit must be at least 64"))
    ncodeunits(text) <= limit && return String(text)
    chars = collect(text)
    marker = "\n… output omitted …\n"
    half = max(1, (limit - ncodeunits(marker)) ÷ 8)
    return String(chars[1:min(half,length(chars))]) * marker *
        String(chars[max(1,length(chars)-half+1):end])
end
