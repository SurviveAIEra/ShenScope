function evidence_fixture(root; mismatch=false, duplicate=false, shifted=false)
    ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
        permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Deny,:process=>Deny,:network=>Deny)))
    left=ProjectState(ctx,GoASTBackend());right=ProjectState(ctx,TreeSitterBackend())
    paths=["a.go","b.go","c.go","tests_test.go"]
    names=["Api","CallerA","CallerB","TestApi"]
    ids=Dict(path=>ShenScope.symbol_id("evidence_fixture",path) for path in paths)
    for (path,name) in zip(paths,names)
        write(joinpath(root,path),"package p\nfunc $(name)() int { return 1 }\n")
    end
    function facts(path;alternate=false)
        name=names[findfirst(==(path),paths)];source=read(joinpath(root,path),String)
        sha=mismatch && alternate && path=="a.go" ? digest(source*"\n") : digest(source)
        location=SourceRange(path,2,2;start_column=alternate && shifted && path=="a.go" ? 2 : 1,end_column=20)
        symbol=CodeSymbol(ids[path],alternate ? :method : :function,name,"p."*name,location,:go,
            Dict{String,Any}("signature"=>alternate ? name*"()::Int" : name*"()","semantic"=>false))
        symbols=CodeSymbol[symbol]
        if duplicate && alternate && path=="a.go"
            push!(symbols,CodeSymbol(ShenScope.symbol_id("duplicate",path),symbol.kind,name,symbol.qualified_name,
                location,:go,deepcopy(symbol.metadata)))
        end
        edge=path in ("b.go","c.go") ? Relation(ids[path],ids["a.go"],:calls,location;
            confidence=path=="b.go" ? 0.7 : 0.85,provenance="synthetic_fixture") :
            path=="tests_test.go" ? Relation(ids[path],ids["c.go"],:calls,location;
                confidence=0.8,provenance="synthetic_fixture") : nothing
        FileFacts(path,sha,symbols,edge===nothing ? Relation[] : Relation[edge],CallReference[],Dict{String,Any}[])
    end
    lf=Dict{String,Union{Nothing,FileFacts}}(path=>facts(path) for path in paths[1:2])
    rf=Dict{String,Union{Nothing,FileFacts}}(path=>facts(path;alternate=true) for path in paths[[1,3,4]])
    ShenScope.install_facts!(left,lf);ShenScope.install_facts!(right,rf)
    left.revision=3;right.revision=7
    args=Dict{String,Any}("backends"=>["go_ast","tree_sitter"])
    (ctx=ctx,left=left,right=right,states=[left,right],ids=ids,args=args)
end

function evidence_error_code(f)
    try
        f();nothing
    catch error
        error isa ShenScopeError || rethrow()
        error.code
    end
end
