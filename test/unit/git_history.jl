@testset "Git history strict framing, capacities and path identity" begin
    head = repeat("a", 40); parent = repeat("b", 40)
    raw = history_test_record(head, [parent], ["2\t1\t space 中文\nfile.jl", "-\t-\tbinary.bin"]) *
        history_test_record(parent, String[], String[])
    commits, truncated = ShenScope.parse_git_history(Vector{UInt8}(codeunits(raw)), head)
    @test !truncated && length(commits) == 2
    @test commits[1].changes[1].path == " space 中文\nfile.jl"
    @test commits[1].changes[1].added == 2 && commits[1].changes[1].removed == 1
    @test commits[1].changes[2].added === nothing && isempty(commits[2].changes)
    @test commits[1].parents == (parent,) && commits[2].ordinal == 2
    limited, truncated = ShenScope.parse_git_history(Vector{UInt8}(codeunits(raw)), head, GitHistoryLimits(;commits=1))
    @test truncated && only(limited).id == head
    overflow = history_test_record(head, String[], ["1\t0\ta.jl", "1\t0\tb.jl", "1\t0\tc.jl"])
    retained, _ = ShenScope.parse_git_history(Vector{UInt8}(codeunits(overflow)), head,
        GitHistoryLimits(;files_per_commit=2, bulk_threshold=2))
    @test only(retained).omitted_changes == 1 && length(only(retained).changes) == 2
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(overflow)), head, GitHistoryLimits(;total_changes=2))
    bad_records = ["1\t0\t../escape", "1\t0\t/absolute", "1\t0\ta//b", "1\t0\t./a", "1\t0\tC:/outside",
        "-\t1\tbad", "1\t-\tbad", "01\t0\ta", "1000000001\t0\ta", "1\t0\t", "1\t0", "1\t0\ta\0trailing"]
    for record in bad_records
        @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(history_test_record(head, String[], [record]))), head)
    end
    duplicate = history_test_record(head, String[], ["1\t0\ta.jl", "2\t0\ta.jl"])
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(duplicate)), head)
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(raw[1:end-1])), head)
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(replace(raw, parent=>repeat("c",40);count=1))), head)
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(history_test_record(head, [head], String[]))), head)
    @test_throws ShenScopeError ShenScope.parse_git_history(Vector{UInt8}(codeunits(history_test_record(head, String[], String[];timestamp="-1"))), head)
    @test_throws ShenScopeError ShenScope.parse_git_history(UInt8[0x00, 0xff, 0x00], head)
    @test_throws ShenScopeError ShenScope.parse_git_history(UInt8[], head)
    sha256_id = repeat("d", 64)
    @test only(first(ShenScope.parse_git_history(Vector{UInt8}(codeunits(history_test_record(sha256_id, String[], String[]))), sha256_id))).id == sha256_id
    @test ShenScope.git_history_public_path("normal/中文.jl")
    for path in (".git/config", "nested/.env.local", ".aws/credentials", "nested/.SSH/key")
        @test !ShenScope.git_history_public_path(path)
    end
    for options in ((;commits=true), (;commits=0), (;commits=513), (;timeout_seconds=NaN),
            (;timeout_seconds=true), (;files_per_commit=2, bulk_threshold=3), (;output_bytes=4*1024*1024+1))
        @test_throws ShenScopeError GitHistoryLimits(;options...)
    end
    @test ShenScope.git_history_version("git version 2.52.0") == "git version 2.52.0"
    @test ShenScope.git_history_version("git version 2.43.0.windows.1") == "git version 2.43.0.windows.1"
    @test_throws ShenScopeError ShenScope.git_history_version("git version 2.42.0")
    @test_throws ShenScopeError ShenScope.git_history_version("unexpected")
end

@testset "History evidence ranking remains bounded and explicit" begin
    @test ShenScope.history_shared_ordinals([1,3,5], [2,3,4,5]) == [3,5]
    rows = [Dict{String,Any}("file"=>"b.jl","score"=>0.5), Dict{String,Any}("file"=>"a.jl","score"=>0.5)]
    @test only(ShenScope.history_rank_candidates!(rows,1))["file"] == "a.jl"
    rows = [Dict{String,Any}("file"=>"a","score"=>1.0,"data"=>repeat("x",64))]
    @test isempty(ShenScope.history_bound_candidate_bytes(rows;maximum=16))
    @test length(ShenScope.history_bound_candidate_bytes(rows;maximum=1024)) == 1
    @test_throws ShenScopeError ShenScope.history_analysis_integer(Dict("limit"=>true),"limit",10,1,1000)
    @test_throws ShenScopeError ShenScope.history_analysis_values(Dict("paths"=>"a.jl"),"paths")
    @test_throws ShenScopeError ShenScope.history_analysis_values(Dict("symbols"=>fill("a",129)),"symbols")
    @test ShenScope.history_log_score(0,100) == 0 && ShenScope.history_log_score(1000,100) == 1
end
