function atomic_write(path::AbstractString, content::AbstractString; mode=0o600)
    mkpath(dirname(path))
    temp,io = mktemp(dirname(path))
    try
        chmod(temp,mode)
        write(io,content)
        flush(io)
        Sys.isunix() && ccall(:fsync,Cint,(Cint,),fd(io)) != 0 &&
            throw(ShenScopeError(:storage,"fsync failed"))
        close(io)
        mv(temp,path;force=true)
    finally
        isopen(io) && close(io)
        isfile(temp) && rm(temp)
    end
    return path
end

function store_lock(f::Function, path::AbstractString)
    mkpath(dirname(path))
    Sys.isunix() || throw(ShenScopeError(:platform,"Cross-process journal locking unavailable on this platform"))
    open(path * ".lock","a+") do io
        chmod(path * ".lock",0o600)
        ccall(:flock,Cint,(Cint,Cint),fd(io),2) == 0 ||
            throw(ShenScopeError(:storage,"Journal lock failed"))
        try
            return f()
        finally
            ccall(:flock,Cint,(Cint,Cint),fd(io),8)
        end
    end
end

mutable struct Journal
    path::String
    max_record_bytes::Int
end
Journal(path::AbstractString) = Journal(String(path),16*1024*1024)

function journal_records(j::Journal; repair_tail=false)
    !isfile(j.path) && return Dict{String,Any}[]
    records = Dict{String,Any}[]
    expected = 1
    good_offset = 0
    open(j.path,"r") do io
        while !eof(io)
            raw = readline(io;keep=true)
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
    if repair_tail && filesize(j.path)>good_offset
        open(j.path,"r+") do io
            truncate(io,good_offset)
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
            Sys.isunix() && ccall(:fsync,Cint,(Cint,),fd(io)) != 0 &&
                throw(ShenScopeError(:storage,"Journal fsync failed"))
        end
        return revision+1
    end
end

function valid_id(id::AbstractString)
    occursin(r"^[a-zA-Z0-9_-]{1,128}$",id) || throw(ShenScopeError(:input,"Invalid identifier"))
    return String(id)
end
