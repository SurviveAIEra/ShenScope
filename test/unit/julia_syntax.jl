@testset "Julia method signatures preserve syntax without executing project code" begin
    mktempdir() do root
        source = """
        module Demo
        abstract type AbstractBox end
        mutable struct Box{T} <: AbstractBox
            value::T
            label
        end
        f(x::T, y=1; k::Int=2) where {T<:Number} = g(x)
        f(x::Int,y::Any) = x
        f(x::Any,y::Int) = y
        f(x::Int...) = sum(x)
        function Base.show(io::IO, x::Box{T}) where T
            println(io,x.value)
        end
        function outer(x)
            inner(y::Int) = y
            inner(x)
        end
        using ..Other: run
        import Base: show
        export f, Box
        include("child.jl")
        include(joinpath(@__DIR__,"dynamic.jl"))
        include("../outside.jl")
        quote
            hidden(x) = x
        end
        @generated generated(x) = :(x)
        error("must never execute")
        end
        """
        facts = julia_project_facts(root,source)
        @test facts.metadata["parse_complete"] && !facts.metadata["source_evaluated"]
        @test isempty(facts.diagnostics)
        @test facts.sha256==digest(source) && isempty(facts.occurrences)
        @test all(symbol->symbol.language==:julia && !symbol.metadata["semantic"], facts.symbols)
        methods = julia_fact_methods(facts)
        @test length(methods)==7
        @test count(symbol->symbol.name=="f",methods)==4
        first_f = only([symbol for symbol in methods if symbol.name=="f" && !isempty(symbol.metadata["where"])])
        data=first_f.metadata
        @test first_f.qualified_name=="Demo.f" && data["module"]=="Demo"
        @test data["minimum_arity"]==1 && data["maximum_arity"]==2
        @test data["positional"][1]["annotation"]=="T"
        @test data["positional"][2]["optional"] && data["positional"][2]["default"]=="1"
        @test only(data["keywords"])["annotation"]=="Int"
        @test only(data["keywords"])["keyword"] && !data["keyword_dispatch"]
        @test only(data["where"])["text"]=="T<:Number"
        @test !data["compiler_confirmed"] && !data["runtime_method_materialized"]
        vararg=only([symbol for symbol in methods if symbol.name=="f" && symbol.metadata["vararg"]])
        @test vararg.metadata["minimum_arity"]==0 && vararg.metadata["maximum_arity"]===nothing
        @test vararg.metadata["positional"][1]["annotation"]=="Int"
        @test only([symbol for symbol in methods if symbol.name=="show"]).qualified_name=="Base.show"
        @test only([symbol for symbol in methods if symbol.name=="inner"]).qualified_name=="Demo.outer.inner"
        @test !any(symbol->symbol.name in ("hidden","generated"),facts.symbols)
        @test length(facts.metadata["julia_imports"])==2
        @test only(facts.metadata["julia_exports"])["module"]=="Demo"
        includes=facts.metadata["julia_includes"]
        @test length(includes)==3 && includes[1]["candidate_path"]=="child.jl"
        @test !includes[1]["executed"] && includes[1]["resolution"]=="literal_relative_path_only"
        @test includes[2]["literal"]===nothing && includes[2]["reason"]=="dynamic_expression"
        @test !includes[3]["resolved"] && includes[3]["reason"]=="outside_workspace"
        @test !isfile(joinpath(root,"child.jl"))
        @test any(call->call["macro"],facts.metadata["julia_calls"])
        @test all(call->!call["compiler_confirmed"] && !call["resolved"],facts.metadata["julia_calls"])
        @test Set(symbol.name for symbol in facts.symbols if symbol.kind==:field)==Set(["value","label"])
        box=only([symbol for symbol in facts.symbols if symbol.name=="Box"])
        @test box.metadata["mutable"] && box.metadata["supertype"]=="AbstractBox"
        @test count(edge->edge.kind==:inherits,facts.relations)==1
        @test all(edge->edge.kind==:contains || edge.confidence<1,facts.relations)
    end
end

@testset "Julia declaration identities survive body edits, lines and type trivia" begin
    mktempdir() do root
        old=julia_project_facts(root,"f(x::Vector{Int}; mode=1) = x\n")
        changed=julia_project_facts(root,"\n# moved\nf(renamed::Vector{ Int }; mode=9) = reverse(renamed)\n")
        @test only(julia_fact_methods(old)).id==only(julia_fact_methods(changed)).id
        different=julia_project_facts(root,"f(x::Vector{Float64}; mode=1)=x\n")
        @test only(julia_fact_methods(old)).id!=only(julia_fact_methods(different)).id
        duplicate=julia_project_facts(root,"f(x::Int)=x\nf(y::Int)=y\n")
        @test length(unique(symbol.id for symbol in julia_fact_methods(duplicate)))==2
        @test [symbol.metadata["syntax_ordinal"] for symbol in julia_fact_methods(duplicate)]==[0,1]
        unicode=julia_project_facts(root,"module 模块\r\n函数(输入::Int)=输入+1\r\nend\r\n")
        method=only(julia_fact_methods(unicode))
        @test method.qualified_name=="模块.函数" && method.location.start_line==2
        @test method.location.start_column==1 && method.location.end_column==ncodeunits("函数(输入::Int)=输入+1")+1
        map=ShenScope.SourceMap("example.jl","module 模块\r\n函数(输入::Int)=输入+1\r\nend\r\n")
        @test ShenScope.source_range_text(map,method.location)=="函数(输入::Int)=输入+1"
        quoted=julia_project_facts(root,"f(x::Val{\"a b\"})=x\nf(x::Val{\"ab\"})=x\n")
        @test length(unique(symbol.id for symbol in julia_fact_methods(quoted)))==2
    end
end

@testset "Malformed Julia source returns bounded diagnostics and no partial declarations" begin
    mktempdir() do root
        facts=julia_project_facts(root,"function broken(\n")
        @test !facts.metadata["parse_complete"] && isempty(julia_fact_methods(facts))
        @test !isempty(facts.diagnostics)
        @test all(item->item["category"]=="error" && item["source"]=="JuliaSyntax",facts.diagnostics)
        @test all(item->item["location"]["column_unit"]=="utf8_byte",facts.diagnostics)
        empty=julia_project_facts(root,"")
        @test empty.metadata["parse_complete"] && length(empty.symbols)==1
        ctx=julia_project_context(root);cancel!(ctx.cancellation)
        @test julia_project_error(()->julia_project_facts(root,"x=1";ctx))==:cancelled
        depth="f(x)="*repeat("(",300)*"x"*repeat(")",300)
        @test julia_project_error(()->julia_project_facts(root,depth))==:graph
        wrong=Dict("path"=>"example.jl","source"=>"x=1","sha256"=>digest("x=2"),"language"=>"julia")
        @test julia_project_error(()->ShenScope.julia_extract_document(wrong,julia_project_context(root)))==:graph
        oversized=repeat("x",ShenScope.JULIA_SYNTAX_MAX_SOURCE+1)
        @test julia_project_error(()->julia_project_facts(root,oversized))==:graph
        comprehensions=join(["v$(index)=[x for x in 1:2 if x>0]" for index in 1:140],"\n")
        @test julia_project_facts(root,comprehensions).metadata["parse_complete"]
    end
end
