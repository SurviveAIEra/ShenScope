@testset "Atomic replacement remains complete to concurrent readers" begin
    mktempdir() do root
        path=joinpath(root,"value.json")
        atomic_write(path,canonical(Dict("version"=>0,"text"=>"中文")))
        done=Threads.Atomic{Bool}(false)
        ready=Channel{Bool}(1)
        reader=Threads.@spawn begin
            reads=0
            while !done[]
                data=parsejson(read(path,String))
                data["text"]=="中文" || error("Invalid snapshot")
                reads+=1
                reads==1 && put!(ready,true)
                yield()
            end
            reads
        end
        take!(ready)
        for version in 1:25
            atomic_write(path,canonical(Dict("version"=>version,"text"=>"中文")))
            yield()
        end
        done[]=true
        @test fetch(reader)>0
        @test parsejson(read(path,String))["version"]==25
        @test length(readdir(root))==1
    end
end

@testset "Oversized unterminated journal input is bounded" begin
    mktempdir() do root
        j=Journal(joinpath(root,"journal.jsonl"),1024)
        write(j.path,repeat("x",2048))
        @test_throws ShenScopeError journal_records(j)
        @test filesize(j.path)==2048
    end
end

@testset "Contended journal locks check cancellation and release after failed checkpoints" begin
    mktempdir() do root
        path = joinpath(root,"transaction")
        ready = Channel{Bool}(1);release = Channel{Bool}(1)
        holder = @async ShenScope.store_lock(path) do
            put!(ready,true);take!(release)
        end
        take!(ready)
        token = CancellationToken();checks = Ref(0);executed = Ref(false)
        waiter = @async try
            ShenScope.store_lock(path;checkpoint=()->begin;checks[] += 1;check_cancelled(token);end) do
                executed[] = true
            end
            nothing
        catch error
            error
        end
        try
            @test timedwait(()->checks[] >= 2,5;pollint=0.01) == :ok
            cancel!(token,"Cancel a pending storage transaction")
            @test timedwait(()->istaskdone(waiter),5;pollint=0.01) == :ok
            @test fetch(waiter) isa ShenScopeError
            @test !executed[]
        finally
            put!(release,true);wait(holder)
        end
        calls = Ref(0)
        @test_throws ShenScopeError ShenScope.store_lock(path;checkpoint=()->begin
            calls[] += 1
            calls[] == 2 && throw(ShenScopeError(:permission,"Revoked after lock acquisition"))
        end) do
            error("Callback must not run")
        end
        @test ShenScope.store_lock(()->:released,path) == :released
    end
end
