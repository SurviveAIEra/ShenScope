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
