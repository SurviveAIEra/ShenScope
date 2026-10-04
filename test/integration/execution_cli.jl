@testset "Security CLI exposes policy without implicit process execution" begin
    mktempdir() do root
        path=joinpath(root,"config.toml");state=joinpath(root,"state")
        write(path,"[permissions]\nread='allow'\nprocess='deny'\nnetwork='deny'\npersistence='deny'\n")
        args=["--root",root,"--state-dir",state,"--config",path]
        @test ShenScope.main(vcat(["security","status"],args))==0
        @test ShenScope.main(vcat(["security","probe"],args))==1
        @test ShenScope.main(vcat(["security","probe","--allow-process"],args))==0
        @test ShenScope.main(vcat(["security","invalid"],args))==1
        @test ShenScope.main(vcat(["doctor"],args))==0
        @test !isdir(joinpath(root,"memory"))
        write(path,"[sandbox]\nbackend='bubblewrap'\nfilesystem='read_only'\nnetwork='closed'\n[permissions]\nread='allow'\nprocess='deny'\nnetwork='deny'\n")
        @test ShenScope.main(vcat(["security","status"],args))==0
        @test ShenScope.main(vcat(["security","probe"],args))==1
    end
end
