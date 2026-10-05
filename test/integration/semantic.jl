include("../fixtures/semantic_transport.jl")

function semantic_snapshot(state)
    lock(state.mutex) do
        Dict(path=>ShenScope.facts_dict(facts) for (path,facts) in state.files)
    end
end

function semantic_cursor(root,path,needle;unit="utf8_byte")
    lines=split(read(joinpath(root,path),String),'\n';keepempty=true)
    line=findlast(text->occursin(needle,text),lines)
    column=first(findfirst(needle,lines[line]))
    unit=="utf16" && (column=length(transcode(UInt16,String(lines[line][1:prevind(lines[line],column)])))+1)
    Dict{String,Any}("file"=>path,"line"=>line,"column"=>column,"column_unit"=>unit)
end

@testset "Actual TypeScript checker resolves aliases, methods, overloads and diagnostics without execution" begin
    mktempdir() do root
        write(joinpath(root,"base.ts"),"""
            export interface Greeter { greet(name: string): string; }
            export class English implements Greeter {
                greet(name: string): string { return "hello " + name; }
            }
            """)
        write(joinpath(root,"math.ts"),"""
            export function add(left: number, right: number): number { return left + right; }
            export function parse(value: string): string;
            export function parse(value: number): number;
            export function parse(value: string | number): string | number { return value; }
            """)
        write(joinpath(root,"unrelated.ts"),"export function add() { return false; }\n")
        write(joinpath(root,"调用.ts"),"""
            import { English } from './base';
            import { add as increment, parse } from './math';
            export function TestGreet(): string {
                const agent = new English();
                const 中文 = "中😀"; return agent.greet(中文) + increment(1, 2) + parse("done");
            }
            """)
        write(joinpath(root,"dynamic.ts"),"""
            export declare const dynamic: any;
            export function Unknown(arg: number) { return dynamic(arg); }
            export const wrong: number = "type error";
            """)
        write(joinpath(root,"never-run.ts"),"""
            import { writeFileSync } from 'node:fs';
            writeFileSync('executed.txt', 'must never happen');
            export const SafeToAnalyze = true;
            """)
        ctx=semantic_context(root);backend=TypeScriptSemanticBackend()
        try
            state=build!(backend,ctx)
            @test length(state.files)==6
            @test state.capabilities.calls==:semantic
            @test state.capabilities.types && state.capabilities.references && state.capabilities.implementations
            @test !state.capabilities.rename
            @test !isfile(joinpath(root,"executed.txt"))
            calls=[edge for edge in values(state.relations) if edge.kind==:calls]
            @test any(edge->state.symbols[edge.src].name=="TestGreet" &&
                state.symbols[edge.dst].name=="greet" && state.symbols[edge.dst].location.file=="base.ts",calls)
            @test any(edge->state.symbols[edge.src].name=="TestGreet" &&
                state.symbols[edge.dst].name=="add" && state.symbols[edge.dst].location.file=="math.ts",calls)
            @test !any(edge->state.symbols[edge.src].name=="TestGreet" && state.symbols[edge.dst].location.file=="unrelated.ts",calls)
            @test any(edge->state.symbols[edge.src].name=="TestGreet" && state.symbols[edge.dst].name=="English",calls)
            chosen=only([state.symbols[edge.dst] for edge in calls if state.symbols[edge.src].name=="TestGreet" && state.symbols[edge.dst].name=="parse"])
            @test occursin("string",chosen.metadata["signature"])
            @test all(edge->startswith(edge.provenance,"compiler:typescript@5.9.2:"),calls)
            @test any(edge->edge.kind==:implements && state.symbols[edge.src].name=="English" && state.symbols[edge.dst].name=="Greeter",values(state.relations))
            @test any(item->item["code"]==2322,state.files["dynamic.ts"].diagnostics)
            @test state.files["dynamic.ts"].metadata["unresolved_calls"]>=1
            @test !isempty(state.files["调用.ts"].occurrences)
            @test any(value->!isempty(value.targets) && occursin("number",value.type_text),state.files["调用.ts"].occurrences)
            @test semantic_snapshot(load_project(backend,ctx))==semantic_snapshot(state)
            @test update!(backend,state,["math.ts"],ctx).revision==state.revision
            greeting=only([symbol for symbol in values(state.symbols) if symbol.qualified_name=="English.greet" && symbol.kind==:method])
            impact=analyze(ImpactAnalyzer(),state,Dict("symbols"=>[greeting.id.value]),ctx)
            @test any(candidate->candidate["symbol"]["name"]=="TestGreet",impact["candidates"])
            tests=analyze(TestSelectionAnalyzer(),state,Dict("symbols"=>[greeting.id.value]),ctx)
            @test any(candidate->candidate["symbol"]["name"]=="TestGreet",tests["candidates"])
            @test haskey(analyze(ArchitectureAnalyzer(),state,Dict(),ctx),"cycles")
            @testset "Navigation returns compiler evidence in both cursor encodings" begin
                query(action,args=Dict())=ShenScope.project_navigation(state,merge(Dict("action"=>action),args),ctx)
                cursor=semantic_cursor(root,"调用.ts","increment(1")
                utf16=semantic_cursor(root,"调用.ts","increment(1";unit="utf16")
                definitions=query("definitions",cursor)
                @test definitions==query("definitions",utf16)
                @test only(definitions["items"])["location"]["file"]=="math.ts"
                @test only(definitions["items"])["name"]=="add"
                @test only(definitions["items"])["indexed_source_sha256"]==state.files["math.ts"].sha256
                @test occursin("number",query("hover",utf16)["type"])
                function_symbol=only([s for s in values(state.symbols) if s.name=="TestGreet"])
                outgoing=query("outgoing_calls",Dict("symbol_id"=>function_symbol.id.value))
                @test Set(item["target"]["name"] for item in outgoing["items"])==Set(["English","greet","add","parse"])
                @test all(item->item["resolution"]=="compiler_static",outgoing["items"])
                incoming=query("incoming_calls",Dict("symbol_id"=>greeting.id.value))
                @test only(incoming["items"])["source"]["name"]=="TestGreet"
                interface=only([s for s in values(state.symbols) if s.name=="Greeter"])
                @test only(query("implementations",Dict("symbol_id"=>interface.id.value))["items"])["symbol"]["name"]=="English"
                refs=query("references",merge(cursor,Dict("include_declarations"=>false,"limit"=>1)))
                @test refs["total"]>=2 && refs["next_offset"]==1
                @test all(item->item["role"]!="declaration",refs["items"])
                next=query("references",merge(cursor,Dict("include_declarations"=>false,"limit"=>1,"offset"=>1)))
                @test next["items"]!=refs["items"]
                @test isempty(query("references",merge(cursor,Dict("offset"=>1000)))["items"])
                diagnostics=query("diagnostics",Dict("file"=>"dynamic.ts","category"=>"error"))
                @test any(item->item["code"]==2322,diagnostics["items"])
                @test all(item->item["file"]=="dynamic.ts",diagnostics["items"])
                config_file=joinpath(root,"cli.toml");write(config_file,"")
                output_file=joinpath(root,"cli-evidence.log")
                exit_code=open(output_file,"w") do output
                    redirect_stdout(output) do
                        ShenScope.main(["project","definitions",cursor["file"],string(utf16["line"]),string(utf16["column"]),
                            "--column-unit","utf16","--backend","typescript","--root",root,
                            "--state-dir",ctx.state_dir,"--config",config_file])
                    end
                end
                @test exit_code==0
                @test ShenScope.parsejson(read(output_file,String))==definitions
                @test isempty(query("definitions",Dict("file"=>"调用.ts","line"=>3,"column"=>1))["items"])
                @test semantic_error_code(()->query("definitions",merge(cursor,Dict("revision"=>state.revision+1))))==:conflict
                @test semantic_error_code(()->query("definitions",merge(cursor,Dict("sha256"=>repeat("0",64)))))==:conflict
                @test semantic_error_code(()->query("references",merge(cursor,Dict("include_declarations"=>1))))==:graph_query
                @test semantic_error_code(()->query("definitions",merge(cursor,Dict("symbol_id"=>greeting.id.value))))==:graph_query
                @test semantic_error_code(()->query("definitions",merge(cursor,Dict("file"=>"../outside.ts"))))==:permission
                @test semantic_error_code(()->query("definitions",merge(cursor,Dict("column_unit"=>"bytes"))))==:graph_query
                # The UI/tool uses the same navigation path and cached revision.
                tool=ProjectTool();tool.manager.states[ShenScope.digest(ctx.root)*":typescript"]=state
                @test execute(tool,merge(cursor,Dict("action"=>"definitions","backend"=>"typescript")),ctx)==definitions
                denied=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
                @test semantic_error_code(()->ShenScope.project_navigation(state,Dict("action"=>"diagnostics"),denied))==:permission
                mktempdir() do other
                    @test semantic_error_code(()->ShenScope.project_navigation(state,Dict("action"=>"diagnostics"),semantic_context(other)))==:permission
                end
                write(joinpath(root,"调用.ts"),read(joinpath(root,"调用.ts"),String)*"// changed\n")
                @test semantic_error_code(()->query("definitions",cursor))==:stale_index
                @test update!(backend,state,["调用.ts"],ctx).revision==2
                @test query("definitions",cursor)["revision"]==2
                write(joinpath(root,"tsconfig.json"),"{}")
                @test semantic_error_code(()->query("definitions",cursor))==:stale_index
                @test update!(backend,state,["tsconfig.json"],ctx).revision==3
                @test query("definitions",cursor)["revision"]==3
                write(joinpath(root,"tsconfig.json"),"{\"compilerOptions\": {\"strict\": false}}")
                @test semantic_error_code(()->query("hover",cursor))==:stale_index
            end
        finally
            backend_close!(backend)
        end
    end
end
