using Random

@testset "Bounded source differences preserve both sides and group separate changes" begin
    rng=MersenneTwister(43)
    alphabet=["中😀","same","","space ","return x", "x\r"]
    options=WorkspaceDiffOptions(;context_lines=2)
    for iteration in 1:160
        before=rand(rng,alphabet,rand(rng,0:12))
        after=rand(rng,alphabet,rand(rng,0:12))
        operations=ShenScope.workspace_diff_operations(before,after,options)
        @test [line.text for line in operations if line.operation!=:add]==before
        @test [line.text for line in operations if line.operation!=:remove]==after
        @test [line.before_line for line in operations if line.operation!=:add]==collect(1:length(before))
        @test [line.after_line for line in operations if line.operation!=:remove]==collect(1:length(after))
    end
    before=join(string.(1:30),"\n")*"\n"
    changed=string.(1:30);changed[2]="second";changed[28]="last"
    after=join(changed,"\n")*"\n"
    diff=workspace_source_diff("sample.py",before,after;options)
    @test length(diff.hunks)==2 && diff.added_lines==2 && diff.removed_lines==2
    projection=workspace_diff_projection(diff)
    @test occursin("+second",projection["text"]) && !projection["preview_truncated"]
    @test projection["before_sha256"]==digest(before) && projection["after_sha256"]==digest(after)
    @test !projection["external_patch_execution_supported"]
    insertion=workspace_source_diff("empty.go","","new\n")
    @test only(insertion.hunks).before_count==0 && insertion.added_lines==1
    deletion=workspace_source_diff("empty.go","old\n","")
    @test only(deletion.hunks).after_count==0 && deletion.removed_lines==1
    newline=workspace_diff_projection(workspace_source_diff("newline.txt","same","same\n"))
    @test newline["changed"] && occursin("Final newline",newline["text"])
    @test isempty(workspace_source_diff("same.txt","same","same").hunks)
end

@testset "Source difference capacities never imply a complete preview" begin
    @test_throws ShenScopeError workspace_source_diff("large.txt","a\nb\nc\n","x\ny\nz\n";
        options=WorkspaceDiffOptions(;maximum_edit_distance=1))
    before=join(string.(1:50),"\n")
    after=replace(before,"2\n"=>"change\n","48\n"=>"other\n")
    limited=workspace_diff_projection(workspace_source_diff("hunks.txt",before,after;
        options=WorkspaceDiffOptions(;maximum_hunks=1,context_lines=0)))
    @test limited["omitted_hunks"]>0 && limited["preview_truncated"]
    long=workspace_diff_projection(workspace_source_diff("long.txt",repeat("中",200),repeat("文",200));maximum_bytes=128)
    @test long["preview_truncated"] && ncodeunits(long["text"])<=128
    @test_throws ShenScopeError workspace_source_diff("bad.txt","a\0b","valid")
end
