const EXTENSION_CONTRIBUTION_KINDS=Set([:tool,:provider,:backend,:analyzer,:projection])
const EXTENSION_MAX_PACKAGES=64
const EXTENSION_MAX_CONTRIBUTIONS=128

abstract type AbstractEvidenceProjection end
projection_name(::AbstractEvidenceProjection)=throw(ShenScopeError(:extension,"Projection must implement its name"))
project_projection(::AbstractEvidenceProjection,::ProjectEvidenceSnapshot,::RuntimeContext)=
    throw(ShenScopeError(:extension,"Projection must implement project_projection"))

struct ExtensionContribution
    name::String
    kind::Symbol
    factory::Function
    cleanup::Function
    function ExtensionContribution(name::String,kind::Symbol,factory::Function,cleanup::Function)
        extension_identifier(name)
        kind in EXTENSION_CONTRIBUTION_KINDS || throw(ShenScopeError(:extension,"Unsupported contribution kind"))
        new(name,kind,factory,cleanup)
    end
end
function ExtensionContribution(name::AbstractString,kind::Symbol,factory::Function;cleanup=(value,ctx)->nothing)
    ExtensionContribution(String(name),kind,factory,cleanup)
end

struct ExtensionBundle
    name::String
    package_uuid::UUID
    version::VersionNumber
    minimum_core::VersionNumber
    maximum_core::VersionNumber
    description::String
    contributions::Vector{ExtensionContribution}
    function ExtensionBundle(name::String,uuid::UUID,version::VersionNumber,minimum::VersionNumber,
            maximum::VersionNumber,description::String,contributions::Vector{ExtensionContribution})
        extension_identifier(name)
        minimum<maximum || throw(ShenScopeError(:extension,"Invalid Core compatibility interval"))
        1<=length(contributions)<=EXTENSION_MAX_CONTRIBUTIONS || throw(ShenScopeError(:extension,"Invalid extension contributions"))
        names=[value.name for value in contributions]
        length(unique(names))==length(names) || throw(ShenScopeError(:extension,"Duplicate extension contribution names"))
        ncodeunits(description)<=4096 || throw(ShenScopeError(:extension,"Extension description exceeds capacity"))
        new(name,uuid,version,minimum,maximum,description,copy(contributions))
    end
end
function ExtensionBundle(name::AbstractString,uuid::UUID,version::VersionNumber,contributions;
        minimum_core=v"0.1.0",maximum_core=v"0.2.0",description="")
    contributions isa AbstractVector &&
        all(value->value isa ExtensionContribution,contributions) || throw(ShenScopeError(:extension,"Invalid extension contributions"))
    description isa AbstractString || throw(ShenScopeError(:extension,"Invalid extension description"))
    ExtensionBundle(String(name),uuid,version,minimum_core,maximum_core,String(description),collect(ExtensionContribution,contributions))
end

mutable struct ExtensionRecord
    bundle::ExtensionBundle
    phase::Symbol
    generation::Int
    instances::Dict{String,Any}
    leases::Dict{String,Int}
    contracts::Dict{String,Dict{String,Any}}
    source::Dict{String,Any}
    failure_stage::Union{Nothing,Symbol}
    cleanup_failures::Int
    activation_context::Union{Nothing,RuntimeContext}
end
mutable struct ExtensionRegistry
    id::String
    root::Union{Nothing,String}
    records::Dict{String,ExtensionRecord}
    revision::Int
    reserved_names::Set{String}
    closed::Bool
    mutex::ReentrantLock
end
ExtensionRegistry(;reserved_names=String[])=ExtensionRegistry(string(uuid4()),nothing,Dict{String,ExtensionRecord}(),0,Set(String.(reserved_names)),false,ReentrantLock())

struct ExtensionLease
    registry::ExtensionRegistry
    extension::String
    contribution::String
    generation::Int
    instance::Any
    token::String
end

function extension_identifier(value::AbstractString)
    occursin(r"^[a-z][a-z0-9_]{0,63}$",value) || throw(ShenScopeError(:extension,"Invalid extension identifier"))
    String(value)
end
extension_target(bundle::ExtensionBundle)="package:"*bundle.name*"@"*string(bundle.package_uuid)
extension_kind(::AbstractTool)=:tool
extension_kind(::AbstractModelProvider)=:provider
extension_kind(::AbstractProjectDataBackend)=:backend
extension_kind(::AbstractAnalyzer)=:analyzer
extension_kind(::AbstractEvidenceProjection)=:projection
extension_kind(value)=throw(ShenScopeError(:extension,"Factory returned an unsupported extension interface"))

function extension_checkpoint(ctx::RuntimeContext;target=nothing,dynamic=false,read=false,tool="extension.inventory")
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    if dynamic
        request=PermissionRequest("extension-checkpoint",:dynamic,"extension.lifecycle",String(target),"Use trusted installed Julia extension")
        permission_decision(ctx.permissions,request)!=Deny || throw(ShenScopeError(:permission,"Extension dynamic authorization was revoked"))
    end
    if read
        request=PermissionRequest("extension-read-checkpoint",:read,tool,String(target),"Read extension evidence")
        permission_decision(ctx.permissions,request)!=Deny || throw(ShenScopeError(:permission,"Extension read authorization was revoked"))
    end
    yield()
end
