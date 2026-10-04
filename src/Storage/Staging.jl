const ATOMIC_STAGING_DIRECTORY=".shenscope-staging"

function atomic_staging_directory(destination::AbstractString;create=false)
    directory=joinpath(dirname(abspath(destination)),ATOMIC_STAGING_DIRECTORY)
    create && mkpath(directory)
    ispath(directory) || return nothing
    isdir(directory) && !islink(directory) && realpath(directory)==directory ||
        throw(ShenScopeError(:storage,"Atomic staging directory is not an owned regular directory"))
    Sys.isunix() && UInt64(stat(directory).uid)!=UInt64(ccall(:geteuid,Cuint,())) &&
        throw(ShenScopeError(:storage,"Atomic staging directory has another owner"))
    create && chmod(directory,0o700)
    directory
end

function create_atomic_stage(destination::AbstractString)
    directory=atomic_staging_directory(destination;create=true)
    temporary,output=mktemp(directory)
    named=joinpath(directory,"snapshot-"*string(uuid4())*".tmp")
    marker=named*".owner.json"
    try
        # Rename the empty exclusive mktemp file. Data is written only after
        # the Core-owned descriptor exists; a crash before then leaves no
        # large unidentifiable file.
        close(output);atomic_replace(temporary,named);output=open(named,"r+")
        descriptor=Dict("schema"=>1,"pid"=>getpid(),"file"=>basename(named),
            "destination"=>basename(destination),"created_at"=>time())
        atomic_write(marker,canonical(descriptor))
        named,marker,output
    catch
        isopen(output) && close(output)
        for path in (temporary,named,marker);isfile(path) && !islink(path) && rm(path);end
        rethrow()
    end
end

function remove_atomic_stage(temporary::String,marker::String)
    for path in (temporary,marker);isfile(path) && !islink(path) && rm(path);end
    directory=dirname(temporary)
    isdir(directory) && !islink(directory) && sync_directory(directory)
    if isdir(directory) && !islink(directory) && isempty(readdir(directory))
        try;rm(directory)
        catch error
            error isa Base.IOError || error isa SystemError || rethrow()
        end
        !ispath(directory) && sync_directory(dirname(directory))
    end
    nothing
end

function staging_process_alive(pid::Int)
    Sys.isunix() || return nothing
    result=ccall(:kill,Cint,(Cint,Cint),pid,0)
    result==0 && return true
    Base.Libc.errno()==3 ? false : nothing
end

function atomic_stage_descriptor(path::String,destination::String)
    isfile(path) && !islink(path) && filesize(path)<=4096 || return nothing
    text=open(input->String(read(input,4097)),path)
    descriptor=try bounded_json_object(text;maximum=4096,max_depth=4,max_nodes=64,error_code=:storage) catch;return nothing;end
    Set(keys(descriptor))==Set(["schema","pid","file","destination","created_at"]) || return nothing
    pid=descriptor["pid"];created=descriptor["created_at"];file=descriptor["file"]
    descriptor["schema"]===1 && pid isa Integer && !(pid isa Bool) && 1<=pid<=typemax(Int32) &&
        created isa Real && !(created isa Bool) && isfinite(created) && created>=0 &&
        file isa AbstractString && occursin(r"^snapshot-[a-f0-9-]{36}\.tmp$",file) &&
        basename(path)==file*".owner.json" && descriptor["destination"]==basename(destination) || return nothing
    descriptor
end

function reclaim_atomic_staging!(destination::AbstractString;minimum_age_seconds=3600.0,checkpoint=()->nothing)
    minimum_age_seconds isa Real && !(minimum_age_seconds isa Bool) &&
        isfinite(minimum_age_seconds) && minimum_age_seconds>=0 || throw(ArgumentError("Invalid staging retention age"))
    destination=abspath(destination);directory=atomic_staging_directory(destination)
    removed=String[];bytes=0;live=0;invalid=0
    directory===nothing && return Dict("removed"=>removed,"reclaimed_bytes"=>bytes,"live"=>live,"unclassified"=>invalid)
    names=readdir(directory);length(names)<=4096 || throw(ShenScopeError(:storage,"Atomic staging descriptor capacity exceeded"))
    for name in names
        endswith(name,".owner.json") || continue
        checkpoint();marker=joinpath(directory,name)
        descriptor=atomic_stage_descriptor(marker,destination)
        if descriptor===nothing;invalid+=1;continue;end
        time()-descriptor["created_at"]>=minimum_age_seconds || continue
        alive=staging_process_alive(Int(descriptor["pid"]))
        if alive!==false;live+=1;continue;end
        temporary=joinpath(directory,descriptor["file"])
        islink(temporary) && (invalid+=1;continue)
        ispath(temporary) && !isfile(temporary) && (invalid+=1;continue)
        if Sys.isunix()
            owner=UInt64(ccall(:geteuid,Cuint,()))
            UInt64(stat(marker).uid)==owner && (!isfile(temporary) || UInt64(stat(temporary).uid)==owner) ||
                (invalid+=1;continue)
        end
        # Recheck the descriptor and liveness immediately before deletion.
        atomic_stage_descriptor(marker,destination)==descriptor && staging_process_alive(Int(descriptor["pid"]))===false || continue
        checkpoint()
        retained=isfile(temporary) ? filesize(temporary) : 0
        remove_atomic_stage(temporary,marker)
        bytes+=retained;push!(removed,descriptor["file"])
    end
    Dict("removed"=>removed,"reclaimed_bytes"=>bytes,"live"=>live,"unclassified"=>invalid)
end
