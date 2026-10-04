struct JournalFileIdentity
    device::UInt64
    inode::UInt64
    bytes::Int
    modified::Float64
    changed::Float64
end
Base.:(==)(left::JournalFileIdentity,right::JournalFileIdentity)=
    left.device==right.device && left.inode==right.inode && left.bytes==right.bytes &&
    left.modified==right.modified && left.changed==right.changed

function journal_file_identity(path::AbstractString)
    islink(path) && throw(ShenScopeError(:storage,"Journal may not be a symlink"))
    ispath(path) || return nothing
    isfile(path) || throw(ShenScopeError(:storage,"Journal must be a regular file"))
    info=stat(path)
    JournalFileIdentity(UInt64(info.device),UInt64(info.inode),Int(info.size),Float64(info.mtime),Float64(info.ctime))
end

mutable struct BoundedStreamWriter <: IO
    output::IOStream
    maximum::Int
    written::Int
end
Base.isopen(writer::BoundedStreamWriter)=isopen(writer.output)
Base.iswritable(::BoundedStreamWriter)=true
Base.isreadable(::BoundedStreamWriter)=false
Base.position(writer::BoundedStreamWriter)=writer.written
Base.flush(writer::BoundedStreamWriter)=flush(writer.output)
function Base.unsafe_write(writer::BoundedStreamWriter,data::Ptr{UInt8},count::UInt)
    count<=UInt(writer.maximum-writer.written) || throw(ShenScopeError(:storage,"Atomic stream exceeds capacity"))
    written=Base.unsafe_write(writer.output,data,count)
    writer.written+=Int(written)
    written==count || throw(ShenScopeError(:storage,"Atomic stream write made incomplete progress"))
    written
end
function Base.write(writer::BoundedStreamWriter,byte::UInt8)
    writer.written<writer.maximum || throw(ShenScopeError(:storage,"Atomic stream exceeds capacity"))
    count=write(writer.output,byte);writer.written+=count;count
end

function atomic_stream_write(f::Function,path::AbstractString;maximum_bytes=128*1024*1024,mode=0o600,
        before_publish=(bytes,result)->true)
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 0<maximum_bytes<=512*1024*1024 ||
        throw(ArgumentError("Invalid atomic stream capacity"))
    destination=abspath(path);directory=dirname(destination)
    mkpath(directory)
    realpath(directory)==directory || throw(ShenScopeError(:storage,"Atomic stream directory may not follow symlinks"))
    journal_file_identity(destination)
    temporary,marker,output=create_atomic_stage(destination)
    writer=BoundedStreamWriter(output,Int(maximum_bytes),0)
    try
        chmod(temporary,mode)
        result=f(writer)
        flush(writer);sync_file(output);close(output)
        publish=before_publish(writer.written,result)
        publish isa Bool || throw(ShenScopeError(:storage,"Atomic publication decision must be Boolean"))
        if publish
            journal_file_identity(destination)
            atomic_replace(temporary,destination)
        end
        (published=publish,bytes=writer.written,result=result)
    finally
        isopen(output) && close(output)
        remove_atomic_stage(temporary,marker)
    end
end
