function evidence_manager_states(manager::ProjectManager,arguments::AbstractDict,ctx::RuntimeContext)
    names=evidence_backend_names(arguments);states=ProjectState[]
    for name in names
        evidence_checkpoint(ctx)
        key=digest(ctx.root)*":"*name
        backend=lock(manager.mutex) do
            project_backend!(manager,name)
        end
        state=lock(manager.mutex) do;get(manager.states,key,nothing);end
        if state===nothing
            candidate=ProjectState(ctx,backend)
            isfile(candidate.journal.path) || throw(ShenScopeError(:evidence_index,
                "Index the "*name*" backend before combining its evidence"))
            state=load_project(backend,ctx;authorized=true)
            state=lock(manager.mutex) do
                get!(manager.states,key,state)
            end
        end
        state.root==ctx.root && state.backend==name || throw(ShenScopeError(:permission,"An evidence index has another workspace or backend"))
        push!(states,state)
    end
    states
end

function evidence_manager_status(manager::ProjectManager,ctx::RuntimeContext)
    authorize!(ctx,:read,"project.evidence",ctx.root;reason="Inspect available project evidence sources")
    names=["tree_sitter","go_ast","codegraph","typescript","julia_syntax"]
    result=Dict{String,Any}[]
    for name in names
        evidence_checkpoint(ctx)
        key=digest(ctx.root)*":"*name
        backend=lock(manager.mutex) do;project_backend!(manager,name);end
        state=lock(manager.mutex) do;get(manager.states,key,nothing);end
        candidate=state===nothing ? ProjectState(ctx,backend) : state
        available=state!==nothing || isfile(candidate.journal.path)
        stamp=state===nothing ? nothing : lock(state.mutex) do
            Dict("revision"=>state.revision,"files"=>length(state.files),"symbols"=>length(state.symbols))
        end
        push!(result,Dict("backend"=>name,"indexed"=>available,"loaded"=>state!==nothing,
            "stamp"=>stamp,"capabilities"=>capability_dict(candidate.capabilities),
            "source_hashes_verified"=>false))
    end
    Dict("sources"=>result,"automatic_indexing"=>false,"private_backend_schemas_exposed"=>false)
end

function project_evidence_action(tool::ProjectTool,arguments::AbstractDict,ctx::RuntimeContext)
    action=get(arguments,"action","")
    action in PROJECT_EVIDENCE_ACTIONS || throw(ShenScopeError(:arguments,"Unknown combined project evidence action"))
    authorize!(ctx,:read,"project.evidence",ctx.root;reason="Combine cached project facts and verify selected source hashes")
    states=evidence_manager_states(tool.manager,arguments,ctx)
    snapshot=project_evidence_snapshot(states,arguments,ctx;authorized=true)
    expected=get(arguments,"expected_evidence_fingerprint",nothing)
    expected===nothing || expected isa AbstractString && expected==snapshot.fingerprint ||
        throw(ShenScopeError(:conflict,"The combined evidence snapshot changed"))
    result=action=="evidence_compare" ? evidence_compare(snapshot,arguments,ctx) :
        action=="evidence_search" ? evidence_search(snapshot,arguments,ctx) :
        action=="evidence_impact" ? analyze(ImpactAnalyzer(),snapshot,arguments,ctx) :
        analyze(TestSelectionAnalyzer(),snapshot,arguments,ctx)
    evidence_verify_snapshot(snapshot,states,ctx)
    result["action"]=action
    result
end
