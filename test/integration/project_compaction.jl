@testset "Real compiler cache compaction preserves navigation, diagnostics and subsequent updates" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:session)
        backend=TypeScriptSemanticBackend()
        write(joinpath(root,"library.ts"),"export function Greet(name: string): string { return name; }\n")
        write(joinpath(root,"main.ts"),"import { Greet } from './library';\nexport function TestGreet() { return Greet('中文😀'); }\nexport const wrong: number = 'error';\n")
        try
            state=build!(backend,ctx)
            for index in 1:4
                write(joinpath(root,"library.ts"),"export function Greet(name: string): string { return name + '$index'; }\n")
                update!(backend,state,["library.ts"],ctx)
            end
            before=graph_snapshot(state);fingerprint=project_fingerprint(state);metadata=deepcopy(state.metadata);revision=state.revision
            symbol=only(s for s in values(state.symbols) if s.name=="Greet" && s.kind==:function)
            navigation=ShenScope.project_navigation(state,Dict("action"=>"incoming_calls","symbol_id"=>symbol.id.value),ctx)
            diagnostics=ShenScope.project_navigation(state,Dict("action"=>"diagnostics"),ctx)
            compact=compact_project!(state,ctx)
            @test compact["compacted"] && compact["saved_bytes"]>0
            @test state.revision==revision && graph_snapshot(state)==before && state.metadata==metadata
            reloaded=load_project(backend,ctx)
            @test project_fingerprint(reloaded)==fingerprint
            @test ShenScope.project_navigation(reloaded,Dict("action"=>"incoming_calls","symbol_id"=>symbol.id.value),ctx)==navigation
            @test ShenScope.project_navigation(reloaded,Dict("action"=>"diagnostics"),ctx)==diagnostics
            write(joinpath(root,"library.ts"),"export function Greet(name: string): number { return name.length; }\n")
            @test update!(backend,reloaded,["library.ts"],ctx).revision==revision+1
            @test project_fingerprint(load_project(backend,ctx))==project_fingerprint(reloaded)
            @test occursin("number",ShenScope.project_navigation(reloaded,Dict("action"=>"hover","symbol_id"=>symbol.id.value),ctx)["type"])
            config=joinpath(root,"cli.toml");write(config,"")
            output=joinpath(root,"cli-result.txt")
            code=open(output,"w") do stream
                redirect_stdout(stream) do
                    ShenScope.main(["project","compact","--backend","typescript","--force","--root",root,
                        "--state-dir",ctx.state_dir,"--config",config,"--allow-persistence"])
                end
            end
            @test code==0
            @test ShenScope.parsejson(read(output,String))["compacted"]
            @test project_fingerprint(load_project(backend,ctx))==project_fingerprint(reloaded)
        finally;backend_close!(backend);end
    end
end
