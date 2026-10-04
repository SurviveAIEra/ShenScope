@testset "Compute limits and strict in-memory JSON" begin
    limits = ShenScope.ComputeLimits()
    @test ShenScope.compute_limits_from_dict(ShenScope.compute_limits_dict(limits)) == limits
    for kwargs in ((;wall_seconds=NaN), (;wall_seconds=true), (;cpu_seconds=0),
            (;address_space_bytes=1), (;input_bytes=128), (;output_bytes=5*1024^2),
            (;source_bytes=true), (;max_tests=0))
        @test_throws ShenScopeError ShenScope.ComputeLimits(;kwargs...)
    end
    @test_throws ShenScopeError ShenScope.compute_limits_from_dict(Dict("unknown"=>1))
    @test_throws ShenScopeError ShenScope.compute_source("", limits)
    @test_throws ShenScopeError ShenScope.compute_source("a\0b", limits)
    @test_throws ShenScopeError ShenScope.compute_source(repeat("a",limits.source_bytes+1), limits)
    @test parsejson("{\"x\":1}") == Dict("x"=>1)
    @test parsejson(codeunits("{\"x\":1}")) == Dict("x"=>1)
    @test parsejson(IOBuffer("{\"x\":1}")) == Dict("x"=>1)
    mktempdir() do root
        path = joinpath(root,"payload.json")
        write(path,"{\"unexpected_file_read\":true}")
        @test_throws Exception parsejson(path)
    end
    @test_throws ShenScopeError ShenScope.compute_frame("{\"x\":1}",1024)
    @test_throws ShenScopeError ShenScope.compute_frame("{\"x\":1,\"x\":2}\n",1024)
    @test_throws ShenScopeError ShenScope.compute_frame("{\"x\":NaN}\n",1024)
    @test_throws ShenScopeError ShenScope.compute_frame("{\"x\":1}\n{\"x\":2}\n",1024)
    profile = Dict("backend"=>"linux-seccomp-compute-v1", "enforced"=>true,
        "thread_synchronized"=>true, "no_new_privileges"=>true, "filesystem_open"=>false,
        "filesystem_write"=>false, "network"=>false, "child_processes"=>false)
    ready = Dict("protocol"=>1,"kind"=>"ready","pid"=>42,"sandbox"=>profile,
        "limits"=>ShenScope.compute_limits_dict(limits))
    @test ShenScope.compute_ready_frame(ready,limits,42) == profile
    for (key,value) in (("protocol",true),("kind","result"),("pid",43),("extra",1))
        @test_throws ShenScopeError ShenScope.compute_ready_frame(merge(ready,Dict(key=>value)),limits,42)
    end
    for key in ("enforced","thread_synchronized","no_new_privileges","network","filesystem_write","child_processes")
        bad = merge(ready,Dict("sandbox"=>merge(profile,Dict(key=>!profile[key]))))
        @test_throws ShenScopeError ShenScope.compute_ready_frame(bad,limits,42)
    end
    frame = Dict("protocol"=>1,"kind"=>"result","id"=>"one","source_sha256"=>digest("x"),
        "selftest"=>true,"results"=>[Dict("value"=>1)],"metrics"=>Dict("compile_seconds"=>0.1,"analyze_seconds"=>0.2))
    @test ShenScope.compute_result_frame(frame,"one",digest("x"),1)["results"][1]["value"] == 1
    for (key,value) in (("id","two"),("source_sha256",digest("y")),("selftest",false),
            ("results",[1]),("metrics",Dict("compile_seconds"=>NaN,"analyze_seconds"=>0.2)),("extra",1))
        @test_throws ShenScopeError ShenScope.compute_result_frame(merge(frame,Dict(key=>value)),"one",digest("x"),1)
    end
end

@testset "Shared writable mapping remains unsafe after descriptor close" begin
    if Sys.islinux()
        mktempdir() do root
            path = joinpath(root,"mapped-host-file.bin")
            write(path,zeros(UInt8,4096))
            descriptor = ccall(:open,Cint,(Cstring,Cint),path,2)
            @test descriptor >= 0
            mapped = ccall(:mmap,Ptr{Cvoid},(Ptr{Cvoid},Csize_t,Cint,Cint,Cint,Clong),C_NULL,4096,3,1,descriptor,0)
            ccall(:close,Cint,(Cint,),descriptor)
            @test mapped != Ptr{Cvoid}(typemax(UInt))
            try
                @test_throws ShenScopeError ShenScope.compute_mapping_audit()
            finally
                ccall(:munmap,Cint,(Ptr{Cvoid},Csize_t),mapped,4096)
            end
            @test ShenScope.compute_mapping_audit() === nothing
        end
    else
        @test_skip "Linux compute mapping audit"
    end
end
