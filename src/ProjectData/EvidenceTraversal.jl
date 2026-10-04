function evidence_seed_keys(snapshot::ProjectEvidenceSnapshot,arguments,ctx::RuntimeContext)
    paths=evidence_paths(arguments,ctx)
    all(path->haskey(snapshot.files,path),paths) || throw(ShenScopeError(:analysis,"A changed evidence path is outside the captured graph"))
    raw=get(arguments,"evidence_keys",String[])
    raw isa AbstractVector && length(raw)<=128 && all(key->key isa AbstractString && occursin(r"^[a-f0-9]{32}$",key),raw) ||
        throw(ShenScopeError(:arguments,"Invalid combined evidence seed identities"))
    keys=Set(String.(raw))
    all(key->haskey(snapshot.symbols,key),keys) || throw(ShenScopeError(:analysis,"A combined evidence seed is absent"))
    for (key,value) in snapshot.symbols
        value.symbol.location.file in paths && push!(keys,key)
    end
    isempty(keys) && throw(ShenScopeError(:analysis,"Select changed files or namespaced evidence keys"))
    sort!(collect(keys))
end

function evidence_neighbors(snapshot::ProjectEvidenceSnapshot,key::String,direction::Symbol)
    adjacency=direction==:reverse ? snapshot.reverse : snapshot.forward
    result=Tuple{String,Dict{String,Any},Float64}[]
    for id in get(adjacency,key,String[])
        value=snapshot.relations[id];relation=value.relation
        relation.kind in (:calls,:uses,:imports,:inherits,:implements,:depends_on) || continue
        relation.confidence>=snapshot.limits.confidence || continue
        next=direction==:reverse ? value.src : value.dst
        step=merge(evidence_relation_dict(value),Dict("step_kind"=>"provider_relation"))
        push!(result,(next,step,relation.confidence))
    end
    if snapshot.limits.bridges
        anchor_id=get(snapshot.member_anchors,key,nothing)
        if anchor_id!==nothing
            anchor=snapshot.anchors[anchor_id]
            if anchor.eligible_bridge && snapshot.limits.confidence<=0.9
                for member in anchor.members
                    member==key && continue
                    step=Dict{String,Any}("step_kind"=>"source_anchor_bridge","anchor_id"=>anchor.id,
                        "src"=>key,"dst"=>member,"confidence"=>0.9,"runtime_equivalence_confirmed"=>false,
                        "location"=>range_dict(anchor.location),"indexed_source_sha256"=>anchor.source_sha256)
                    push!(result,(member,step,0.9))
                end
            end
        end
    end
    sort!(result;by=item->(item[1],canonical(item[2])))
end

function evidence_traverse(snapshot::ProjectEvidenceSnapshot,seeds::Vector{String},ctx::RuntimeContext;
        direction::Symbol=:reverse)
    direction in (:forward,:reverse) || throw(ShenScopeError(:arguments,"Invalid evidence traversal direction"))
    discovered=Set(seeds)
    queue=Tuple{String,Int,Float64,Vector{Dict{String,Any}}}[(key,0,1.0,Dict{String,Any}[]) for key in seeds]
    hits=Dict{String,Any}[];position=1;truncated=false;steps=0
    while position<=length(queue)
        key,depth,confidence,path=queue[position];position+=1
        evidence_checkpoint(ctx)
        push!(hits,Dict("key"=>key,"depth"=>depth,"confidence"=>confidence,"steps"=>path,
            "observation"=>evidence_symbol_dict(snapshot.symbols[key])))
        depth>=snapshot.limits.depth && continue
        for (next,step,weight) in evidence_neighbors(snapshot,key,direction)
            steps+=1
            steps<=snapshot.limits.relations+8*snapshot.limits.symbols ||
                throw(ShenScopeError(:capacity,"Combined evidence traversal edge budget exceeded"))
            next in discovered && continue
            if length(discovered)>=snapshot.limits.symbols
                truncated=true;continue
            end
            push!(discovered,next)
            witness=copy(path);push!(witness,step)
            push!(queue,(next,depth+1,min(confidence,weight),witness))
        end
    end
    Dict("hits"=>hits,"truncated"=>truncated,"seeds"=>copy(seeds),"steps_examined"=>steps,
        "direction"=>String(direction),"bridge_depth_cost"=>1,"confidence_kind"=>"minimum_recorded_heuristic")
end
