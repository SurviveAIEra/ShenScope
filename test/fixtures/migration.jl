function migration_fixture(root::String;cycle=false, confidence=0.8)
    ctx = RuntimeContext(root;state_dir=joinpath(root,"state"),
        permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:process=>Deny,:network=>Deny,:persistence=>Deny)))
    state = ProjectState(ctx,GoASTBackend())
    paths = ["a.jl","b.jl","c.jl","d.jl","tests/t.jl"]
    names = ["Api","Caller","SecondCaller","OtherCaller","TestCaller"]
    ids = Dict(path=>ShenScope.symbol_id("migration_fixture",path) for path in paths)
    edges = [("b.jl","a.jl"),("c.jl","b.jl"),("d.jl","a.jl"),("tests/t.jl","c.jl")]
    cycle && push!(edges,("b.jl","c.jl"))
    facts = Dict{String,Union{Nothing,FileFacts}}()
    for (path,name) in zip(paths,names)
        mkpath(dirname(joinpath(root,path)))
        source=name*"() = nothing\n";write(joinpath(root,path),source)
        symbol=CodeSymbol(ids[path],:function,name,name,SourceRange(path,1,1),:julia,Dict{String,Any}())
        relations=[Relation(ids[from],ids[to],:calls,SourceRange(path,1,1);confidence,provenance="synthetic_fixture") for (from,to) in edges if from==path]
        facts[path]=FileFacts(path,digest(source),[symbol],relations,CallReference[],Dict{String,Any}[])
    end
    ShenScope.install_facts!(state,facts)
    state.revision=1
    (ctx=ctx,state=state,ids=ids)
end

function migration_adjacency(nodes::Vector{String},edges::Vector{Tuple{String,String}})
    forward=Dict(node=>Set{String}() for node in nodes)
    reverse=Dict(node=>Set{String}() for node in nodes)
    for (source,target) in edges;push!(forward[source],target);push!(reverse[target],source);end
    forward,reverse
end

function migration_reachability(forward,seed)
    seen=Set{String}();queue=[seed]
    while !isempty(queue)
        node=pop!(queue);node in seen && continue;push!(seen,node);append!(queue,collect(forward[node]))
    end
    seen
end
