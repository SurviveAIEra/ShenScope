function sync_file(io::IOStream)
    if Sys.iswindows()
        handle=Base.Libc._get_osfhandle(Base.RawFD(fd(io)))
        ccall((:FlushFileBuffers,"kernel32"),Int32,(Ptr{Cvoid},),handle)!=0 ||
            throw(ShenScopeError(:storage,"File flush failed"))
    elseif Sys.isunix()
        ccall(:fsync,Cint,(Cint,),fd(io))==0 || throw(ShenScopeError(:storage,"File flush failed"))
    else
        throw(ShenScopeError(:platform,"Durable file flush is unavailable"))
    end
end

function sync_directory(path::AbstractString)
    Sys.isunix() || return
    directory=ccall(:open,Cint,(Cstring,Cint),path,0)
    directory>=0 || throw(ShenScopeError(:storage,"Cannot open directory for flush"))
    try
        ccall(:fsync,Cint,(Cint,),directory)==0 || throw(ShenScopeError(:storage,"Directory flush failed"))
    finally
        ccall(:close,Cint,(Cint,),directory)
    end
end

function atomic_replace(source::AbstractString,destination::AbstractString)
    if Sys.iswindows()
        src=vcat(transcode(UInt16,String(source)),UInt16(0))
        dst=vcat(transcode(UInt16,String(destination)),UInt16(0))
        ccall((:MoveFileExW,"kernel32"),Int32,(Ptr{UInt16},Ptr{UInt16},UInt32),src,dst,0x00000009)!=0 ||
            throw(ShenScopeError(:storage,"Atomic file replacement failed"))
    elseif Sys.isunix()
        ccall(:rename,Cint,(Cstring,Cstring),source,destination)==0 ||
            throw(ShenScopeError(:storage,"Atomic file replacement failed"))
        sync_directory(dirname(destination))
        dirname(source)==dirname(destination) || sync_directory(dirname(source))
    else
        throw(ShenScopeError(:platform,"Atomic replacement is unavailable"))
    end
end

function atomic_write(path::AbstractString, content::AbstractString; mode=0o600)
    mkpath(dirname(path))
    temp,io = mktemp(dirname(path))
    try
        chmod(temp,mode)
        write(io,content)
        flush(io)
        sync_file(io)
        close(io)
        atomic_replace(temp,path)
    finally
        isopen(io) && close(io)
        isfile(temp) && rm(temp)
    end
    return path
end

function store_lock(f::Function, path::AbstractString;checkpoint=()->nothing)
    checkpoint()
    mkpath(dirname(path))
    open(path * ".lock","a+") do io
        chmod(path * ".lock",0o600)
        overlap=zeros(UInt64,4)
        deadline=time()+30
        if Sys.iswindows()
            Sys.WORD_SIZE==64 || throw(ShenScopeError(:platform,"Windows locking requires a 64-bit runtime"))
            handle=Base.Libc._get_osfhandle(Base.RawFD(fd(io)))
            while ccall((:LockFileEx,"kernel32"),Int32,(Ptr{Cvoid},UInt32,UInt32,UInt32,UInt32,Ptr{UInt64}),
                    handle,0x00000003,0,0xffffffff,0xffffffff,overlap)==0
                code=ccall((:GetLastError,"kernel32"),UInt32,())
                code==33 || throw(ShenScopeError(:storage,"Journal lock failed"))
                time()<deadline || throw(ShenScopeError(:storage,"Journal lock timeout"))
                checkpoint()
                sleep(0.005)
            end
        elseif Sys.isunix()
            while ccall(:flock,Cint,(Cint,Cint),fd(io),6)!=0
                Base.Libc.errno() in (11,35) || throw(ShenScopeError(:storage,"Journal lock failed"))
                time()<deadline || throw(ShenScopeError(:storage,"Journal lock timeout"))
                checkpoint()
                sleep(0.005)
            end
        else
            throw(ShenScopeError(:platform,"Cross-process locking is unavailable"))
        end
        try
            checkpoint()
            return f()
        finally
            if Sys.iswindows()
                handle=Base.Libc._get_osfhandle(Base.RawFD(fd(io)))
                ccall((:UnlockFileEx,"kernel32"),Int32,(Ptr{Cvoid},UInt32,UInt32,UInt32,Ptr{UInt64}),
                    handle,0,0xffffffff,0xffffffff,overlap)
            else
                ccall(:flock,Cint,(Cint,Cint),fd(io),8)
            end
        end
    end
end

function bounded_record(io::IO,max_bytes::Int)
    result=IOBuffer(;maxsize=max_bytes,sizehint=min(max_bytes,8192))
    while !eof(io)
        byte=read(io,UInt8)
        position(result)<max_bytes || throw(ShenScopeError(:storage,"Oversized journal record"))
        write(result,byte)
        byte==0x0a && break
    end
    return String(take!(result))
end

mutable struct Journal
    path::String
    max_record_bytes::Int
end
Journal(path::AbstractString) = Journal(String(path),16*1024*1024)

function journal_records(j::Journal; repair_tail=false, valid_bytes=nothing)
    valid_bytes !== nothing && (valid_bytes[] = 0)
    !isfile(j.path) && return Dict{String,Any}[]
    records = Dict{String,Any}[]
    expected = 1
    good_offset = 0
    open(j.path,"r") do io
        while !eof(io)
            raw = bounded_record(io,j.max_record_bytes)
            ncodeunits(raw) <= j.max_record_bytes || throw(ShenScopeError(:storage,"Oversized journal record"))
            if !endswith(raw,"\n")
                break
            end
            frame = try parsejson(raw) catch
                throw(ShenScopeError(:storage,"Corrupt complete journal record"))
            end
            get(frame,"sequence",0)==expected || throw(ShenScopeError(:storage,"Journal sequence mismatch"))
            get(frame,"schema",0)==1 || throw(ShenScopeError(:storage,"Unknown journal schema"))
            get(frame,"sha256","")==digest(canonical(frame["record"])) ||
                throw(ShenScopeError(:storage,"Journal checksum mismatch"))
            push!(records,frame["record"])
            expected += 1
            good_offset = position(io)
        end
    end
    valid_bytes !== nothing && (valid_bytes[] = good_offset)
    if repair_tail && filesize(j.path)>good_offset
        open(j.path,"r+") do io
            truncate(io,good_offset)
            flush(io);sync_file(io)
        end
    end
    return records
end

function append_record!(j::Journal,record::AbstractDict; expected_revision=nothing)
    return store_lock(j.path) do
        records = journal_records(j;repair_tail=true)
        revision = length(records)
        expected_revision !== nothing && revision != expected_revision &&
            throw(ShenScopeError(:conflict,"Journal revision changed"))
        frame = Dict("schema"=>1,"sequence"=>revision+1,"record"=>record,
            "sha256"=>digest(canonical(record)))
        raw = canonical(frame) * "\n"
        ncodeunits(raw) <= j.max_record_bytes || throw(ShenScopeError(:storage,"Record exceeds journal limit"))
        open(j.path,"a") do io
            chmod(j.path,0o600)
            write(io,raw);flush(io)
            sync_file(io)
        end
        return revision+1
    end
end

function valid_id(id::AbstractString)
    occursin(r"^[a-zA-Z0-9_-]{1,128}$",id) || throw(ShenScopeError(:input,"Invalid identifier"))
    return String(id)
end
