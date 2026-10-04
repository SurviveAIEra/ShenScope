struct AnalyzerGraphSnapshot
    data::Dict{String,Any}
    revision::Int
    fingerprint::String
    symbols::Dict{String,Dict{String,Any}}
    relations::Dict{String,Dict{String,Any}}
    seed_ids::Set{String}
end

function analyzer_graph_limits(request::AbstractDict)
    symbols = get(request,"max_symbols",5000);relations = get(request,"max_relations",20000)
    depth = get(request,"max_depth",3);direction = get(request,"direction","reverse")
    for (name,value,maximum) in (("symbols",symbols,20000),("relations",relations,100000))
        value isa Integer && !(value isa Bool) && 1 <= value <= maximum ||
            throw(ShenScopeError(:arguments,"Invalid analyzer graph "*name*" capacity"))
    end
    depth isa Integer && !(depth isa Bool) && 0 <= depth <= 32 && direction in ("forward","reverse") ||
        throw(ShenScopeError(:arguments,"Invalid analyzer graph traversal limits"))
    (symbols=Int(symbols),relations=Int(relations),depth=Int(depth),direction=Symbol(direction))
end

function analyzer_graph_snapshot(state::ProjectState,request::AbstractDict,ctx::RuntimeContext)
    state.root == ctx.root || throw(ShenScopeError(:permission,"Analyzer project belongs to another workspace"))
    authorize!(ctx,:read,"analysis.graph",ctx.root;reason="Read versioned project graph facts for an isolated analyzer")
    project_journal_scope(state,ctx)
    limits = analyzer_graph_limits(request)
    lock(state.mutex) do
        project_storage_checkpoint(ctx)
        seeds = analysis_seeds(state,request)
        all(id -> haskey(state.symbols,id),seeds) || throw(ShenScopeError(:analysis,"Analyzer graph seed does not exist"))
        truncated = false
        if isempty(seeds)
            length(state.symbols) <= limits.symbols ||
                throw(ShenScopeError(:capacity,"Project graph exceeds analyzer capacity; select paths or symbols"))
            ids = sort!(collect(keys(state.symbols)))
            scope = "project"
        else
            traversal = graph_traverse(state,seeds;direction=limits.direction,max_depth=limits.depth,max_nodes=limits.symbols,ctx)
            ids = SymbolId[SymbolId(hit["symbol"]["id"]) for hit in traversal["hits"]]
            sort!(ids);truncated = traversal["truncated"]
            scope = "neighborhood"
        end
        selected = Set(ids)
        symbols = Dict{String,Dict{String,Any}}()
        relations = Dict{String,Dict{String,Any}}()
        files = Dict{String,String}()
        for id in ids
            project_storage_checkpoint(ctx)
            symbol = state.symbols[id]
            workspace_path(ctx.root,symbol.location.file)
            symbols[id.value] = deepcopy(symbol_dict(symbol))
            facts = get(state.files,symbol.location.file,nothing)
            facts !== nothing && (files[symbol.location.file] = facts.sha256)
        end
        # Visit local adjacency of selected symbols instead of scanning every
        # unrelated relation when the caller requested a small neighborhood.
        edge_ids = Set{String}()
        for id in ids
            project_storage_checkpoint(ctx)
            union!(edge_ids,get(state.forward,id,Set{String}()))
        end
        for id in sort!(collect(edge_ids))
            project_storage_checkpoint(ctx)
            edge = state.relations[id]
            edge.src in selected && edge.dst in selected || continue
            length(relations) < limits.relations || throw(ShenScopeError(:capacity,"Analyzer graph relation capacity exceeded"))
            workspace_path(ctx.root,edge.location.file)
            relations[id] = deepcopy(relation_dict(edge))
        end
        fingerprint = project_fingerprint(state;checkpoint=()->project_storage_checkpoint(ctx))
        data = Dict{String,Any}("format"=>1,"backend"=>state.backend,"revision"=>state.revision,
            "fingerprint"=>fingerprint,"coverage"=>capability_dict(state.capabilities),"scope"=>scope,
            "truncated"=>truncated,"seed_ids"=>[id.value for id in seeds],
            "symbols"=>[symbols[id] for id in sort!(collect(keys(symbols)))],
            "relations"=>[relations[id] for id in sort!(collect(keys(relations)))],
            "files"=>[Dict("path"=>path,"sha256"=>files[path]) for path in sort!(collect(keys(files)))])
        AnalyzerGraphSnapshot(data,state.revision,fingerprint,symbols,relations,Set(id.value for id in seeds))
    end
end

function analyzer_graph_current!(snapshot::AnalyzerGraphSnapshot,state::ProjectState,ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    permission_decision(ctx.permissions,PermissionRequest("analysis-graph-current",:read,"analysis.graph",ctx.root,"Publish graph analysis")) != Deny ||
        throw(ShenScopeError(:permission,"Project graph permission was revoked"))
    state.root == ctx.root || throw(ShenScopeError(:permission,"Analyzer project scope changed"))
    project_journal_scope(state,ctx)
    lock(state.mutex) do
        state.revision == snapshot.revision && project_fingerprint(state;checkpoint=()->project_storage_checkpoint(ctx)) == snapshot.fingerprint ||
            throw(ShenScopeError(:conflict,"Project index changed during analysis; rerun on the current revision"))
    end
    nothing
end
