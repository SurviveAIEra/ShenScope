module ShenScopeSparseEvidenceExt
using ShenScope, SparseArrays, UUIDs
import ShenScope: projection_name,project_projection,projection_neighbors,projection_storage_kind
projection_storage_kind(::SparseMatrixCSC)=:sparse

struct SparseEvidenceProjection <: AbstractEvidenceProjection end
projection_name(::SparseEvidenceProjection)="sparse_evidence"

function project_projection(::SparseEvidenceProjection,snapshot::ProjectEvidenceSnapshot,ctx::RuntimeContext)
    snapshot.root==ctx.root || throw(ShenScopeError(:permission,"Evidence projection belongs to another workspace"))
    ShenScope.authorize!(ctx,:read,"project.evidence",ctx.root;reason="Project verified source claims into sparse dependency matrices")
    ShenScope.evidence_verify_files(snapshot,ctx)
    keys=sort!(collect(Base.keys(snapshot.symbols)));positions=Dict(key=>index for (index,key) in enumerate(keys))
    rows=Int[];columns=Int[];weights=Float64[];origins=Dict{Tuple{Int,Int},Vector{String}}()
    provider_count=0;bridge_count=0
    for key in keys
        ShenScope.evidence_checkpoint(ctx)
        for (next,step,confidence) in ShenScope.evidence_neighbors(snapshot,key,:forward)
            src=positions[key];dst=positions[next]
            push!(rows,dst);push!(columns,src);push!(weights,confidence)
            if step["step_kind"]=="provider_relation"
                origin=step["key"];provider_count+=1
            else
                origin="anchor:"*step["anchor_id"]*":"*key*":"*next;bridge_count+=1
            end
            push!(get!(Vector{String},origins,(src,dst)),origin)
        end
    end
    for ids in values(origins);sort!(ids);end
    # Rows are destinations and columns sources. Duplicate facts keep their
    # origin lists; weights summarize them by maximum, never by addition.
    forward=sparse(rows,columns,weights,length(keys),length(keys),max)
    reverse=sparse(transpose(forward))
    ShenScope.evidence_verify_files(snapshot,ctx)
    EvidenceMatrixProjection(ctx.root,snapshot.fingerprint,keys,positions,forward,reverse,origins,
        Dict(source.backend=>source.revision for source in snapshot.sources),provider_count,bridge_count)
end

function projection_neighbors(value::EvidenceMatrixProjection{<:SparseMatrixCSC},key::AbstractString,
        ctx::RuntimeContext;direction=:forward)
    value.root==ctx.root || throw(ShenScopeError(:permission,"Evidence matrix belongs to another workspace"))
    direction in (:forward,:reverse) || throw(ShenScopeError(:arguments,"Invalid matrix traversal direction"))
    ShenScope.authorize!(ctx,:read,"project.evidence",ctx.root;reason="Read sparse indexed dependency neighbors")
    ShenScope.evidence_checkpoint(ctx)
    position=get(value.positions,String(key),nothing)
    position===nothing && throw(ShenScopeError(:arguments,"Evidence projection key is absent"))
    matrix=direction==:forward ? value.forward : value.reverse;rows=rowvals(matrix);weights=nonzeros(matrix)
    result=Dict{String,Any}[]
    for index in nzrange(matrix,position)
        ShenScope.evidence_checkpoint(ctx)
        other=rows[index];pair=direction==:forward ? (position,other) : (other,position)
        push!(result,Dict("key"=>value.keys[other],"weight"=>weights[index],"origins"=>copy(value.origins[pair]),
            "runtime_execution_confirmed"=>false,"fingerprint"=>value.fingerprint))
    end
    sort!(result;by=item->item["key"])
end

function shenscope_extension_bundle()
    ExtensionBundle("sparse_evidence",UUID("3c0e50a5-18b4-4d3a-90e1-bcd141d94adb"),ShenScope.VERSION,
        [ExtensionContribution("dependency_matrix",:projection,ctx->SparseEvidenceProjection())];
        description="Optional sparse dependency matrices preserving source origins and revision vectors")
end
end
