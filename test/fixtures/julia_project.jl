function julia_project_context(root; rules=Dict(:read=>Allow, :persistence=>Allow,
        :process=>Deny, :network=>Deny, :dynamic=>Deny))
    RuntimeContext(root; state_dir=joinpath(root, "state"), permissions=PermissionPolicy(; rules))
end

function julia_project_facts(root, source; path="example.jl", ctx=julia_project_context(root))
    write(joinpath(root, path), source)
    document = Dict{String,Any}("path"=>path, "source"=>source, "sha256"=>digest(source), "language"=>"julia")
    ShenScope.julia_extract_document(document, ctx)
end

function julia_project_error(f)
    try
        f(); nothing
    catch error
        error isa ShenScopeError || rethrow()
        error.code
    end
end

julia_fact_methods(facts) = [symbol for symbol in facts.symbols if symbol.kind==:method]
julia_facts_snapshot(state) = ShenScope.canonical(Dict(path=>ShenScope.facts_dict(facts) for (path,facts) in state.files))
