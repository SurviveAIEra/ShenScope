struct JournalWalk
    records::Int
    committed_bytes::Int
    torn_bytes::Int
end

function journal_frame_record(raw::AbstractString,sequence::Int,maximum::Int)
    frame=bounded_json_object(raw;maximum,max_depth=32,max_nodes=1_000_000,error_code=:storage)
    Set(keys(frame))==Set(["schema","sequence","record","sha256"]) ||
        throw(ShenScopeError(:storage,"Unexpected journal frame fields"))
    frame["schema"]===1 && frame["sequence"] isa Integer && !(frame["sequence"] isa Bool) &&
        frame["sequence"]==sequence || throw(ShenScopeError(:storage,"Journal schema or sequence mismatch"))
    record=frame["record"]
    record isa AbstractDict && frame["sha256"] isa AbstractString &&
        frame["sha256"]==digest(canonical(record)) || throw(ShenScopeError(:storage,"Journal record checksum mismatch"))
    Dict{String,Any}(record)
end

function walk_journal(f::Function,journal::Journal;maximum_bytes=128*1024*1024,checkpoint=()->nothing)
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && maximum_bytes>0 ||
        throw(ArgumentError("Invalid journal capacity"))
    0<journal.max_record_bytes<=32*1024*1024 || throw(ShenScopeError(:storage,"Invalid journal frame capacity"))
    before=journal_file_identity(journal.path)
    before===nothing && return JournalWalk(0,0,0)
    before.bytes<=maximum_bytes || throw(ShenScopeError(:storage,"Journal exceeds replay capacity"))
    count=0;good_bytes=0
    open(journal.path,"r") do input
        while !eof(input)
            checkpoint()
            raw=bounded_record(input,journal.max_record_bytes)
            endswith(raw,"\n") || break
            record=journal_frame_record(raw,count+1,journal.max_record_bytes)
            count+=1;good_bytes=Int(position(input))
            f(record,count,good_bytes)
        end
    end
    before==journal_file_identity(journal.path) || throw(ShenScopeError(:conflict,"Journal changed during replay"))
    JournalWalk(count,good_bytes,before.bytes-good_bytes)
end

function journal_frame_text(record::AbstractDict,sequence::Int,maximum::Int)
    sequence>0 || throw(ShenScopeError(:storage,"Invalid journal frame sequence"))
    frame=canonical(Dict("schema"=>1,"sequence"=>sequence,"record"=>record,"sha256"=>digest(canonical(record))))*"\n"
    ncodeunits(frame)<=maximum || throw(ShenScopeError(:storage,"Journal frame exceeds capacity"))
    frame
end

function truncate_journal!(journal::Journal,bytes::Int)
    identity=journal_file_identity(journal.path)
    identity===nothing && (bytes==0 ? (return nothing) : throw(ShenScopeError(:storage,"Journal disappeared")))
    0<=bytes<=identity.bytes || throw(ShenScopeError(:storage,"Invalid journal recovery boundary"))
    identity.bytes==bytes && return
    open(journal.path,"r+") do output
        truncate(output,bytes);flush(output);sync_file(output)
    end
end
