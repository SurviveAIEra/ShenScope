@testset "Pkg weak dependency activates a sparse evidence extension only after import" begin
    before=optional_extension_status()["sparse_evidence"]["loaded"]
    @test !before
    Base.require(Base.PkgId(Base.UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf"),"SparseArrays"))
    @test optional_extension_status()["sparse_evidence"]["loaded"]
    module_value=Base.get_extension(ShenScope,:ShenScopeSparseEvidenceExt)
    @test module_value!==nothing
    mktempdir() do root
        fixture=evidence_fixture(root);ctx=fixture.ctx;ctx.permissions.rules[:dynamic]=Allow
        registry=ExtensionRegistry()
        bundle=Base.invokelatest(getfield(module_value,:shenscope_extension_bundle))
        @test register_extension!(registry,bundle,ctx)["phase"]=="inactive"
        @test activate_extension!(registry,"sparse_evidence",ctx)["contributions"][1]["contract"]["valid"]
        snapshot=project_evidence_snapshot(fixture.states,fixture.args,ctx)
        projected=with_extension_instance(registry,"sparse_evidence","dependency_matrix",ctx) do projection
            Base.invokelatest(project_projection,projection,snapshot,ctx)
        end
        summary=projection_summary(projected)
        @test summary["nodes"]==5 && summary["provider_relation_claims"]==3
        @test summary["source_anchor_steps"]==2 && summary["occupied_dependency_pairs"]==5
        @test summary["source_revisions"]==Dict("go_ast"=>3,"tree_sitter"=>7)
        @test !summary["dense_matrix_materialized"]
        key=ShenScope.evidence_symbol_key("go_ast",fixture.ids["a.go"])
        reverse=Base.invokelatest(projection_neighbors,projected,key,ctx;direction=:reverse)
        @test length(reverse)==2
        @test any(item->startswith(only(item["origins"]),"anchor:"),reverse)
        @test all(item->!item["runtime_execution_confirmed"],reverse)
        @test extension_error_code(()->Base.invokelatest(projection_neighbors,projected,key,ctx;direction=:sideways))==:arguments
        @test deactivate_extension!(registry,"sparse_evidence",ctx)["phase"]=="inactive"
        @test optional_extension_status()["sparse_evidence"]["loaded"]
    end
end
