const MODEL_ROUTE_FALLBACK_CODES = (:transport,:timeout,:server,:rate_limit,:stream_interrupted,:circuit_open)
const MODEL_ROUTE_NATIVE_FIELDS = ("reasoning_content","reasoning_items","thinking_blocks","parts")

struct ModelSelection
    provider_id::String
    model::String
    options_json::String
end
Base.show(io::IO,value::ModelSelection) = print(io,"ModelSelection(",repr(value.provider_id),", ",repr(value.model),")")

struct ModelProfile
    id::String
    description::String
    selection::ModelSelection
    capabilities::ModelCapabilities
end

struct ModelRoleRoute
    role::String
    profiles::Tuple{Vararg{String}}
    fallback_codes::Tuple{Vararg{Symbol}}
end

mutable struct ModelFleet
    providers::Dict{String,HTTPProvider}
    profiles::Dict{String,ModelProfile}
    roles::Dict{String,ModelRoleRoute}
    default_role::String
    revision::String
    circuits::ModelCircuitManager
    active::Dict{String,Tuple{String,String,String}}
    history::Vector{Dict{String,Any}}
    mutex::ReentrantLock
    max_active::Int
    max_history::Int
    closed::Bool
end
Base.show(io::IO,fleet::ModelFleet) = print(io,"ModelFleet(bounded configured routes)")

struct RoutedProvider <: AbstractModelProvider
    fleet::ModelFleet
    role::String
    function RoutedProvider(fleet::ModelFleet,role::String)
        haskey(fleet.roles,role) || throw(ShenScopeError(:config,"Unknown model route role"))
        lock(fleet.mutex) do;fleet.closed && throw(ShenScopeError(:runtime,"Model routing runtime is closed"));end
        new(fleet,role)
    end
end
Base.show(io::IO,provider::RoutedProvider) = print(io,"RoutedProvider(",repr(provider.role),")")
provider_name(provider::RoutedProvider) = "route/"*provider.role

struct ModelRouteCandidate
    profile_id::String
    provider_id::String
    provider::HTTPProvider
    request::ModelRequest
    wire_bytes::Int
    estimated_tokens::Int
end
Base.show(io::IO,candidate::ModelRouteCandidate) = print(io,"ModelRouteCandidate(",repr(candidate.profile_id),")")

struct ModelRoutePlan
    role::String
    revision::String
    request_sha256::String
    candidates::Vector{ModelRouteCandidate}
    excluded::Vector{Dict{String,Any}}
end
Base.show(io::IO,plan::ModelRoutePlan) = print(io,"ModelRoutePlan(",repr(plan.role),", ",length(plan.candidates)," eligible)")

model_route_owner(ctx::RuntimeContext) = (ctx.root,ctx.state_dir,ctx.session_id)
