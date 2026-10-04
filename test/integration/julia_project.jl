@testset "Julia 1/5/20-file deltas match full extraction and durable replay" begin
    for changed_count in (1,5,20)
        mktempdir() do root
            ctx=julia_project_context(root);backend=JuliaSyntaxBackend()
            paths=["file_"*lpad(string(index),2,'0')*".jl" for index in 1:24]
            for (index,path) in enumerate(paths)
                write(joinpath(root,path),"module Shared\nf_$(index)(x::Int)=x+$(index)\nend\n")
            end
            state=build!(backend,ctx);original=julia_facts_snapshot(state)
            @test length(state.files)==24 && state.revision==1
            no_change=update!(backend,state,paths,ctx)
            @test isempty(no_change.changed_files) && state.revision==1
            for (index,path) in enumerate(paths[1:changed_count])
                write(joinpath(root,path),"module Shared\nf_$(index)(x::Float64)=x-$(index)\nend\n")
            end
            delta=update!(backend,state,paths[1:changed_count],ctx)
            @test length(delta.changed_files)==changed_count && state.revision==2
            @test julia_facts_snapshot(state)!=original
            documents=ShenScope.source_documents(ctx,paths)
            oracle=ProjectState(ctx,backend)
            extracted=ShenScope.extract_files(backend,documents,ctx;full=true)
            changes=Dict{String,Union{Nothing,FileFacts}}(facts.path=>facts for facts in extracted)
            ShenScope.install_facts!(oracle,changes)
            @test julia_facts_snapshot(state)==julia_facts_snapshot(oracle)
            @test Set(keys(state.relations))==Set(keys(oracle.relations))
            replay=load_project(backend,ctx)
            @test replay.revision==2 && julia_facts_snapshot(replay)==julia_facts_snapshot(state)
            @test Set(keys(replay.relations))==Set(keys(state.relations))
            compact=compact_project!(state,ctx;force=true)
            @test compact["compacted"]
            compacted=load_project(backend,ctx)
            @test julia_facts_snapshot(compacted)==julia_facts_snapshot(state)
            rm(joinpath(root,paths[end]))
            deletion=update!(backend,state,[paths[end]],ctx)
            @test deletion.changed_files==[paths[end]] && length(state.files)==23
            @test !any(symbol->symbol.location.file==paths[end],values(state.symbols))
            @test julia_facts_snapshot(load_project(backend,ctx))==julia_facts_snapshot(state)
        end
    end
end

@testset "Julia indexing uses independent read and persistence gates without a process grant" begin
    mktempdir() do root
        write(joinpath(root,"source.jl"),"f(x)=x\n")
        approved=Symbol[]
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),
            permissions=PermissionPolicy(;rules=Dict(:read=>Ask,:persistence=>Ask,:process=>Deny,:network=>Deny)),
            approve=request->begin push!(approved,request.category);:once;end)
        state=build!(JuliaSyntaxBackend(),ctx)
        @test :read in approved && :persistence in approved
        @test !(:process in approved) && !(:network in approved)
        @test state.revision==1 && length(state.files)==1
        before=read(state.journal.path)
        revoked=RuntimeContext(root;state_dir=ctx.state_dir,
            permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Ask,:process=>Deny)),
            approve=request->begin revoked.permissions.rules[:persistence]=Deny;:once;end)
        write(joinpath(root,"source.jl"),"f(x::Int)=x\n")
        @test julia_project_error(()->update!(JuliaSyntaxBackend(),state,["source.jl"],revoked))==:permission
        @test read(state.journal.path)==before && state.revision==1
    end
end
