function owned_project_test_catalog(manager::ProjectTestManager,id,ctx::RuntimeContext)
    identifier=project_test_text(id,"catalog ID",64)
    occursin(r"^[0-9a-f]{64}$",identifier) || throw(ShenScopeError(:testing,"Invalid catalog ID"))
    lock(manager.mutex) do
        entry=get(manager.catalogs,identifier,nothing)
        entry===nothing && throw(ShenScopeError(:testing,"Test catalog does not exist or has been retired; discover again"))
        entry[1]==operation_scope(ctx) || throw(ShenScopeError(:permission,"Test catalog belongs to another conversation or workspace"))
        deepcopy(entry[2])
    end
end

function read_project_test_catalog(manager::ProjectTestManager,id,ctx::RuntimeContext)
    authorize!(ctx,:read,"testing",ctx.root;reason="Read owned project test declarations")
    catalog=owned_project_test_catalog(manager,id,ctx)
    for marker in catalog.markers
        path=joinpath(ctx.root,marker.path)
        authorize!(ctx,:read,"testing",path;reason="Read the retained project test declaration")
        project_test_checkpoint(ctx;read_target=path)
    end
    project_test_checkpoint(ctx;read_target=ctx.root)
    project_test_catalog_view(catalog)
end

function select_project_test_candidate(manager::ProjectTestManager,catalog_id,candidate_id,ctx::RuntimeContext)
    catalog=owned_project_test_catalog(manager,catalog_id,ctx)
    id=project_test_text(candidate_id,"candidate ID",64)
    position=findfirst(candidate->candidate.id==id,catalog.candidates)
    position===nothing && throw(ShenScopeError(:testing,"Test candidate is absent from this owned catalog"))
    catalog,catalog.candidates[position]
end

function validate_project_test_candidate(candidate::ProjectTestCandidate,ctx::RuntimeContext)
    digest(canonical(project_test_candidate_body(candidate)))==candidate.id || throw(ShenScopeError(:conflict,"Test candidate changed"))
    candidate.framework in PROJECT_TEST_FRAMEWORKS || throw(ShenScopeError(:testing,"Unknown test reporting framework"))
    cwd=project_test_workspace_directory(ctx,candidate.cwd)
    project_test_checkpoint(ctx;read_target=cwd)
    for marker in candidate.markers
        text=read_scoped_text(ctx,ctx.root,marker.path,max(64,marker.bytes);tool="testing",reason="Recheck the selected test declaration")
        digest(text)==marker.sha256 && ncodeunits(text)==marker.bytes || throw(ShenScopeError(:conflict,"Test declaration changed; discover again before running"))
    end
    cwd
end
