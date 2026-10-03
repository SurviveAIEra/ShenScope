@testset "Actual compiler frames cannot forge ownership, coordinates, edges or identity" begin
    mktempdir() do root
        write(joinpath(root,"main.ts"),"export function 中文(x: number): number { return x; }\nexport const emoji = '😀'; 中文(1);\n")
        ctx=semantic_context(root);backend=TypeScriptSemanticBackend()
        try
            inputs=ShenScope.project_inputs(backend,ProjectState(ctx,backend),String[],ctx;full=true)
            config=inputs.extras["configuration"];roots=inputs.extras["roots"];stamp=inputs.extras["input_sha256"]
            ShenScope.backend_prepare!(backend,ctx)
            raw=ShenScope.worker_request(backend.worker,"semantic",Dict("version"=>1,"root"=>root,
                "documents"=>inputs.documents,"roots"=>roots,"options"=>config.options,
                "config_sha256"=>config.sha256,"input_sha256"=>stamp),ctx)
            normalize(value)=ShenScope.compiler_result_facts(value,inputs.documents,config,roots,stamp)
            @test only(normalize(raw)).path=="main.ts"
            corruptions=[
                value->(value["version"]=true),
                value->(value["compiler_version"]="0.0"),
                value->(value["input_sha256"]=repeat("0",64)),
                value->(value["config_sha256"]=repeat("0",64)),
                value->(value["files"][1]["path"]="../outside.ts"),
                value->(value["files"][1]["sha256"]=repeat("0",64)),
                value->push!(value["files"],deepcopy(value["files"][1])),
                value->empty!(value["files"]),
                value->(value["files"][1]["symbols"][1]["kind"]="unknown"),
                value->(value["files"][1]["symbols"][1]["parent_key"]=value["files"][1]["symbols"][1]["key"]),
                value->(value["files"][1]["symbols"][1]["selection"]["end"]["line"]=99),
                value->(value["files"][1]["occurrences"][1]["range"]["start"]["character"]=true),
                value->(value["files"][1]["occurrences"][1]["targets"][1]["path"]="foreign.ts"),
                value->(value["files"][1]["edges"][1]["provenance"]="guess"),
                value->(value["files"][1]["edges"][1]["dst"]["key"]="absent"),
                value->(value["statistics"]["occurrences"]+=1),
                value->(value["statistics"]["library_bytes"]=33*1024*1024),
            ]
            for corrupt in corruptions
                value=deepcopy(raw);corrupt(value)
                @test_throws ShenScopeError normalize(value)
            end
            # Newly appearing files and source symlink substitutions abort before persistence.
            write(joinpath(root,"new.ts"),"export const added = 1;")
            @test semantic_error_code(()->ShenScope.project_verify_inputs(backend,inputs,ctx))==:conflict
            rm(joinpath(root,"new.ts"))
            write(joinpath(root,"main.ts"),"export const changed = 2;")
            @test semantic_error_code(()->ShenScope.project_verify_inputs(backend,inputs,ctx))==:conflict
        finally;backend_close!(backend);end
    end
end
