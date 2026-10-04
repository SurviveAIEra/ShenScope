struct EvidenceMatrixProjection{M}
    root::String
    fingerprint::String
    keys::Vector{String}
    positions::Dict{String,Int}
    forward::M
    reverse::M
    origins::Dict{Tuple{Int,Int},Vector{String}}
    source_revisions::Dict{String,Int}
    provider_relations::Int
    bridge_steps::Int
end

projection_storage_kind(::Any)=:unknown
projection_storage_kind(::Matrix)=:dense

function projection_summary(projection::EvidenceMatrixProjection)
    size(projection.forward)==(length(projection.keys),length(projection.keys)) &&
        size(projection.reverse)==size(projection.forward) || throw(ShenScopeError(:extension_contract,"Invalid evidence matrix dimensions"))
    Dict("fingerprint"=>projection.fingerprint,"nodes"=>length(projection.keys),
        "occupied_dependency_pairs"=>length(projection.origins),"provider_relation_claims"=>projection.provider_relations,
        "source_anchor_steps"=>projection.bridge_steps,"source_revisions"=>copy(projection.source_revisions),
        "weight_aggregation"=>"maximum_recorded_weight_per_pair","runtime_equivalence_confirmed"=>false,
        "storage_kind"=>String(projection_storage_kind(projection.forward)),
        "dense_matrix_materialized"=>projection_storage_kind(projection.forward)==:sparse ? false :
            projection_storage_kind(projection.forward)==:dense ? true : nothing)
end
projection_neighbors(::EvidenceMatrixProjection,key::AbstractString,ctx::RuntimeContext;direction=:forward)=
    throw(ShenScopeError(:extension,"The optional matrix extension must implement neighbors"))

function optional_extension_status()
    module_value=Base.get_extension(@__MODULE__,:ShenScopeSparseEvidenceExt)
    Dict("sparse_evidence"=>Dict("loaded"=>module_value!==nothing,"weak_dependency"=>"SparseArrays",
        "extension_module"=>"ShenScopeSparseEvidenceExt","automatic_registry_activation"=>false))
end
function register_optional_extension!(registry::ExtensionRegistry,name::AbstractString,ctx::RuntimeContext)
    name=="sparse_evidence" || throw(ShenScopeError(:extension,"Unknown optional Core extension"))
    extension_scope!(registry,ctx)
    target="package:sparse_evidence@3c0e50a5-18b4-4d3a-90e1-bcd141d94adb"
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Load the optional SparseArrays evidence projection in trusted Core")
    if Base.JLOptions().use_compiled_modules==1
        authorize!(ctx,:process,"extension.precompile",target;reason="Julia may compile its optional SparseArrays extension")
        authorize!(ctx,:persistence,"extension.precompile",target;reason="Julia may write the optional extension's package cache")
    end
    extension_checkpoint(ctx;target,dynamic=true)
    Base.require(Base.PkgId(UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf"),"SparseArrays"))
    module_value=Base.get_extension(@__MODULE__,:ShenScopeSparseEvidenceExt)
    module_value===nothing && throw(ShenScopeError(:extension_load,"Julia did not activate the optional package extension"))
    bundle=Base.invokelatest(getfield(module_value,:shenscope_extension_bundle))
    register_extension!(registry,bundle,ctx;authorized=true,source=Dict("parent_package"=>"ShenScope",
        "weak_dependency"=>"SparseArrays","activation"=>"Pkg_extensions","dependency_sources_verified"=>false))
end
