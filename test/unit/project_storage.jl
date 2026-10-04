include("../fixtures/project_storage_backend.jl")

function storage_error_code(f)
    try;f();nothing
    catch error
        error isa ShenScopeError || rethrow();error.code
    end
end

@testset "Compaction cancellation, expired budgets and post-approval denial preserve the cache" begin
    mktempdir() do root
        owner=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:once)
        backend=SnapshotFixtureBackend();write(joinpath(root,"a.jl"),"value=1")
        state=build!(backend,owner);before=read(state.journal.path);identity=state.journal_identity
        cancelled=RuntimeContext(root;state_dir=owner.state_dir,approve=request->:once)
        cancel!(cancelled.cancellation)
        @test storage_error_code(()->compact_project!(state,cancelled;force=true))==:cancelled
        expired=RuntimeContext(root;state_dir=owner.state_dir,approve=request->:once)
        expired.budget.started_ns=time_ns()-UInt64(4000*10^9)
        @test storage_error_code(()->compact_project!(state,expired;force=true))==:budget
        changed=RuntimeContext(root;state_dir=owner.state_dir,approve=request->begin
            request.category==:persistence && (changed.permissions.rules[:persistence]=Deny)
            :once
        end)
        @test storage_error_code(()->compact_project!(state,changed;force=true))==:permission
        @test read(state.journal.path)==before && state.journal_identity==identity
        old_limit=state.journal.max_record_bytes;state.journal.max_record_bytes=64
        @test storage_error_code(()->compact_project!(state,owner;force=true))==:storage
        @test read(state.journal.path)==before && state.journal_identity==identity
        state.journal.max_record_bytes=old_limit
        @test length(readdir(dirname(state.journal.path)))==2
    end
end

@testset "Actual Julia process replacement fences a stale parent without losing facts" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:once)
        backend=SnapshotFixtureBackend();write(joinpath(root,"a.jl"),"value=1")
        state=build!(backend,ctx);fingerprint=project_fingerprint(state)
        script=joinpath(root,"compact_child.jl")
        fixture=abspath(joinpath(@__DIR__,"../fixtures/project_storage_backend.jl"))
        write(script,"""
            using ShenScope
            include(ARGS[2])
            ctx=RuntimeContext(ARGS[1];state_dir=joinpath(ARGS[1],"state"),approve=request->:once)
            state=load_project(SnapshotFixtureBackend(),ctx)
            result=compact_project!(state,ctx;force=true)
            write(joinpath(ARGS[1],"result.json"),canonical(result))
            """)
        command=Cmd([joinpath(Sys.BINDIR,"julia"),"--startup-file=no","--project="*abspath(joinpath(@__DIR__,"../..")),script,root,fixture])
        child=run(pipeline(command;stdout=devnull,stderr=devnull);wait=false)
        try
            @test timedwait(()->process_exited(child),120;pollint=0.05)==:ok
            wait(child);@test success(child)
            @test ShenScope.parsejson(read(joinpath(root,"result.json"),String))["fingerprint"]==fingerprint
            @test storage_error_code(()->ShenScope.persist_delta!(state,Dict{String,Union{Nothing,FileFacts}}()))==:conflict
            @test project_fingerprint(load_project(backend,ctx))==fingerprint
        finally
            !process_exited(child) && kill(child,Base.SIGKILL);wait(child)
        end
    end
end

@testset "Killed snapshot writer leaves the published file intact and one identifiable temporary" begin
    Sys.isunix() && mktempdir() do root
        destination=joinpath(root,"published");write(destination,"published-value")
        script=joinpath(root,"crash_writer.jl");ready=joinpath(root,"ready")
        write(script,"""
            using ShenScope
            ShenScope.atomic_stream_write(ARGS[1]) do output
                write(output,"incomplete-new-value");flush(output)
                write(ARGS[2],"ready")
                while true;sleep(0.1);end
            end
            """)
        command=Cmd([joinpath(Sys.BINDIR,"julia"),"--startup-file=no","--project="*abspath(joinpath(@__DIR__,"../..")),script,destination,ready])
        child=run(pipeline(command;stdout=devnull,stderr=devnull);wait=false)
        try
            @test timedwait(()->isfile(ready),120;pollint=0.05)==:ok
            kill(child,Base.SIGKILL);wait(child)
            @test read(destination,String)=="published-value"
            stage=joinpath(root,ShenScope.ATOMIC_STAGING_DIRECTORY)
            scratch=filter(name->endswith(name,".tmp"),readdir(stage))
            @test length(scratch)==1 && read(joinpath(stage,only(scratch)),String)=="incomplete-new-value"
            @test length(readdir(stage))==2
            reclaimed=ShenScope.reclaim_atomic_staging!(destination;minimum_age_seconds=0)
            @test reclaimed["removed"]==scratch && reclaimed["reclaimed_bytes"]==ncodeunits("incomplete-new-value")
            @test !ispath(stage)
            @test length(readdir(root))==3
        finally
            !process_exited(child) && kill(child,Base.SIGKILL);wait(child)
        end
    end
end

@testset "Bounded atomic streams publish once and discard incomplete or rejected output" begin
    mktempdir() do root
        path=joinpath(root,"value");write(path,"original")
        result=ShenScope.atomic_stream_write(path;maximum_bytes=16) do output
            write(output,"中文");write(output,UInt8('!'));position(output)
        end
        @test result.published && result.bytes==7 && result.result==7
        @test read(path,String)=="中文!"
        identity=ShenScope.journal_file_identity(path)
        for (maximum,writer) in ((2,output->write(output,"😀")),(16,output->begin;write(output,"partial");error("fixture failure");end))
            @test_throws Exception ShenScope.atomic_stream_write(writer,path;maximum_bytes=maximum)
            @test ShenScope.journal_file_identity(path)==identity
            @test read(path,String)=="中文!"
        end
        @test !ShenScope.atomic_stream_write(output->write(output,"discard"),path;before_publish=(bytes,result)->false).published
        @test ShenScope.journal_file_identity(path)==identity
        @test length(readdir(root))==1
        @test_throws ArgumentError ShenScope.atomic_stream_write(output->nothing,path;maximum_bytes=true)
        @test storage_error_code(()->ShenScope.atomic_stream_write(output->nothing,path;before_publish=(bytes,result)->1))==:storage
        if !Sys.iswindows()
            symlink(path,joinpath(root,"alias"))
            @test storage_error_code(()->ShenScope.atomic_stream_write(output->nothing,joinpath(root,"alias")))==:storage
            @test read(path,String)=="中文!"
        end
    end
end

@testset "Streaming journal validates framing without accumulating history or repairing corruption" begin
    mktempdir() do root
        journal=Journal(joinpath(root,"data"),4096)
        for index in 1:3;ShenScope.append_record!(journal,Dict("index"=>index));end
        original=read(journal.path,String);visited=Int[]
        walk=ShenScope.walk_journal(journal) do record,sequence,ending
            push!(visited,record["index"]);@test sequence==record["index"] && ending>0
        end
        @test visited==[1,2,3] && walk.records==3 && walk.torn_bytes==0
        write(journal.path,original*"{\"partial\":")
        walk=ShenScope.walk_journal((record,sequence,ending)->nothing,journal)
        @test walk.committed_bytes==ncodeunits(original) && walk.torn_bytes>0
        @test filesize(journal.path)>walk.committed_bytes
        for content in (replace(original,"\"sequence\":1"=>"\"sequence\":true"),
                replace(original,"\"schema\":1"=>"\"schema\":true"),replace(original,"\"index\":1"=>"\"index\":9"),
                "{\"schema\":1,\"schema\":1}\n")
            write(journal.path,content);bytes=read(journal.path)
            @test storage_error_code(()->ShenScope.walk_journal((record,sequence,ending)->nothing,journal))==:storage
            @test read(journal.path)==bytes
        end
        write(journal.path,original)
        @test storage_error_code(()->ShenScope.walk_journal((record,sequence,ending)->nothing,journal;maximum_bytes=8))==:storage
        @test storage_error_code(()->ShenScope.walk_journal(journal) do record,sequence,ending
            sequence==1 && write(journal.path,original*" ")
        end)==:conflict
    end
end

@testset "Project compaction retains revision/facts and fences stale writers and recovery" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:session)
        backend=SnapshotFixtureBackend();write(joinpath(root,"a.jl"),"value=0")
        state=build!(backend,ctx)
        for index in 1:12
            write(joinpath(root,"a.jl"),"value=$index");update!(backend,state,["a.jl"],ctx)
        end
        stale=load_project(backend,ctx);facts=graph_snapshot(state);fingerprint=project_fingerprint(state)
        revision=state.revision;before=state.journal_bytes
        result=compact_project!(state,ctx;expected_revision=revision)
        @test result["compacted"] && result["saved_bytes"]>0 && state.journal_bytes<before
        @test state.revision==revision && graph_snapshot(state)==facts && project_fingerprint(state)==fingerprint
        @test state.journal_sequence==3
        replay=load_project(backend,ctx)
        @test replay.revision==revision && graph_snapshot(replay)==facts
        @test project_fingerprint(replay)==fingerprint
        @test storage_error_code(()->compact_project!(stale,ctx;force=true))==:conflict
        old_identity=state.journal_identity
        @test !compact_project!(state,ctx)["compacted"]
        @test state.journal_identity==old_identity
        @test storage_error_code(()->compact_project!(state,ctx;expected_revision=revision+1))==:conflict
        @test storage_error_code(()->compact_project!(state,ctx;force=1))==:graph
        denied=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Deny)))
        @test storage_error_code(()->compact_project!(state,denied;force=true))==:permission
        read_denied=RuntimeContext(root;state_dir=ctx.state_dir,permissions=PermissionPolicy(;rules=Dict(:read=>Deny)))
        @test storage_error_code(()->load_project(backend,read_denied))==:permission
        foreign=RuntimeContext(root;state_dir=joinpath(root,"elsewhere"),approve=request->:once)
        @test storage_error_code(()->compact_project!(state,foreign;force=true))==:permission
        write(joinpath(root,"a.jl"),"value=99")
        @test update!(backend,state,["a.jl"],ctx).revision==revision+1
        @test project_fingerprint(load_project(backend,ctx))==project_fingerprint(state)
        # A second snapshot at the same logical revision has identical size,
        # but a different file identity must still reject the stale writer.
        same_size_stale=load_project(backend,ctx)
        compact_project!(state,ctx;force=true)
        same_size_stale=load_project(backend,ctx);snapshot_bytes=state.journal_bytes
        compact_project!(state,ctx;force=true)
        @test state.journal_bytes==snapshot_bytes
        @test storage_error_code(()->ShenScope.persist_delta!(same_size_stale,Dict{String,Union{Nothing,FileFacts}}()))==:conflict
        snapshot=read(state.journal.path,String);snapshot_revision=state.revision
        ShenScope.append_record!(state.journal,Dict("kind"=>"project_begin","revision"=>snapshot_revision+1,"root"=>ctx.root,"backend"=>state.backend))
        open(state.journal.path,"a") do output;write(output,"{\"torn\":");end
        incomplete_bytes=read(state.journal.path)
        @test storage_error_code(()->load_project(backend,denied))==:permission
        @test read(state.journal.path)==incomplete_bytes
        restored=load_project(backend,ctx)
        @test restored.revision==snapshot_revision && read(state.journal.path,String)==snapshot
        @test project_fingerprint(restored)==project_fingerprint(state)
        # A broken initial snapshot cannot be "recovered" by deleting it.
        lines=split(snapshot,'\n';keepempty=false)
        incomplete=join(lines[1:end-1],'\n')*"\n";write(state.journal.path,incomplete)
        @test storage_error_code(()->load_project(backend,ctx))==:storage
        @test read(state.journal.path,String)==incomplete
        write(state.journal.path,snapshot)
        header=ShenScope.parsejson(lines[1]);header["record"]["fingerprint"]=repeat("0",64)
        forged=ShenScope.journal_frame_text(header["record"],1,state.journal.max_record_bytes)*join(lines[2:end],'\n')*"\n"
        write(state.journal.path,forged)
        @test storage_error_code(()->load_project(backend,ctx))==:storage
        @test read(state.journal.path,String)==forged
        write(state.journal.path,snapshot)
        @test length(readdir(dirname(state.journal.path)))==2
    end
end

@testset "Staging reclamation preserves live, foreign, symlinked and malformed artifacts" begin
    mktempdir() do root
        destination=joinpath(root,"cache")
        ShenScope.atomic_stream_write(destination) do output
            write(output,"live-snapshot")
            result=ShenScope.reclaim_atomic_staging!(destination;minimum_age_seconds=0)
            @test isempty(result["removed"]) && result["live"]==1
            @test length(readdir(joinpath(root,ShenScope.ATOMIC_STAGING_DIRECTORY)))==2
        end
        @test read(destination,String)=="live-snapshot"
        directory=joinpath(root,ShenScope.ATOMIC_STAGING_DIRECTORY);mkpath(directory)
        malformed=joinpath(directory,"bad.owner.json");write(malformed,"{broken}")
        @test ShenScope.reclaim_atomic_staging!(destination;minimum_age_seconds=0)["unclassified"]==1
        @test read(malformed,String)=="{broken}"
        foreign,marker,output=ShenScope.create_atomic_stage(joinpath(root,"other-cache"))
        try
            write(output,"foreign");flush(output)
            result=ShenScope.reclaim_atomic_staging!(destination;minimum_age_seconds=0)
            @test isempty(result["removed"]) && isfile(foreign) && isfile(marker)
        finally
            close(output);ShenScope.remove_atomic_stage(foreign,marker)
        end
        if Sys.isunix()
            name="snapshot-"*string(Base.UUID(1))*".tmp"
            symlink(destination,joinpath(directory,name))
            descriptor=Dict("schema"=>1,"pid"=>typemax(Int32),"file"=>name,
                "destination"=>basename(destination),"created_at"=>0.0)
            write(joinpath(directory,name*".owner.json"),canonical(descriptor))
            @test isempty(ShenScope.reclaim_atomic_staging!(destination;minimum_age_seconds=0)["removed"])
            @test islink(joinpath(directory,name)) && read(destination,String)=="live-snapshot"
        end
    end
end

@testset "Empty committed snapshot and metadata survive round trip" begin
    mktempdir() do root
        ctx=RuntimeContext(root;state_dir=joinpath(root,"state"),approve=request->:once)
        backend=SnapshotFixtureBackend();state=ProjectState(ctx,backend)
        state.metadata=Dict{String,Any}("source"=>"中文😀")
        @test compact_project!(state,ctx;force=true)["compacted"]
        replay=load_project(backend,ctx)
        @test replay.revision==0 && isempty(replay.files) && replay.metadata==state.metadata
        @test replay.journal_sequence==2
        @test project_fingerprint(replay)==project_fingerprint(state)
    end
end
