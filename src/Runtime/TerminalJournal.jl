function terminal_append!(journal::TerminalJournal,text::String;observed::Int=0)
    bytes=Vector{UInt8}(codeunits(text))
    lock(journal.mutex) do
        journal.observed_bytes+=observed
        append!(journal.data,bytes);journal.next_offset+=length(bytes)
        excess=length(journal.data)-journal.limit
        if excess>0
            stop=excess
            while stop<length(journal.data) && (journal.data[stop+1]&0xc0)==0x80;stop+=1;end
            deleteat!(journal.data,1:stop);journal.first_offset+=stop
        end
        (journal.first_offset,journal.next_offset)
    end
end

function terminal_page(journal::TerminalJournal;offset::Integer=0,max_bytes::Integer=TERMINAL_MAX_PAGE)
    !(offset isa Bool) && 0<=offset<=typemax(Int) || throw(ShenScopeError(:arguments,"Invalid terminal offset"))
    !(max_bytes isa Bool) && 4<=max_bytes<=TERMINAL_MAX_PAGE || throw(ShenScopeError(:arguments,"Invalid terminal page size"))
    lock(journal.mutex) do
        offset<=journal.next_offset || throw(ShenScopeError(:terminal_cursor,"Terminal cursor is ahead of retained output"))
        start=max(Int(offset),journal.first_offset)
        index=start-journal.first_offset+1
        index<=length(journal.data) && (journal.data[index]&0xc0)==0x80 &&
            throw(ShenScopeError(:terminal_cursor,"Terminal cursor splits a UTF-8 character"))
        count=min(Int(max_bytes),journal.next_offset-start)
        while count>0 && index+count<=length(journal.data) && (journal.data[index+count]&0xc0)==0x80;count-=1;end
        text=count==0 ? "" : String(copy(journal.data[index:index+count-1]))
        Dict("text"=>text,"from_offset"=>start,"next_offset"=>start+count,
            "retained_from"=>journal.first_offset,"total_bytes"=>journal.next_offset,
            "observed_raw_bytes"=>journal.observed_bytes,"lost_bytes"=>start-Int(offset),
            "more"=>start+count<journal.next_offset,"offset_unit"=>"filtered_utf8_bytes")
    end
end

function terminal_filter!(filter::TerminalFilter,input::Vector{UInt8};final=false)
    decoded=feed_utf8!(filter.decoder,input)
    final && (decoded*=finish_utf8!(filter.decoder))
    decoded=replace(decoded,'\u009b'=>"\e[",'\u009d'=>"\e]",'\u0090'=>"\eP",
        '\u009f'=>"\e_",'\u009e'=>"\e^",'\u0098'=>"\eX",'\u009c'=>"\e\\")
    decoded=replace(decoded,r"[\u0080-\u009f]"=>"")
    output=UInt8[]
    for byte in codeunits(decoded)
        if filter.state==:text
            if byte==0x1b
                filter.state=:escape;empty!(filter.sequence);push!(filter.sequence,byte)
            elseif byte in (0x09,0x0a,0x0d,0x08) || byte>=0x20 && byte!=0x7f
                push!(output,byte)
            else
                filter.discarded_bytes+=1
            end
        elseif filter.state==:escape
            push!(filter.sequence,byte)
            if byte==UInt8('[')
                filter.state=:csi
            elseif byte in UInt8[']','P','_','^','X']
                filter.discarded_bytes+=length(filter.sequence);empty!(filter.sequence);filter.state=:string
            elseif byte in UInt8['7','8','D','E','M','c','=','>']
                append!(output,filter.sequence);empty!(filter.sequence);filter.state=:text
            else
                filter.discarded_bytes+=length(filter.sequence);empty!(filter.sequence);filter.state=:text
            end
        elseif filter.state==:csi
            push!(filter.sequence,byte)
            if 0x40<=byte<=0x7e
                parameters=filter.sequence[3:end-1]
                valid=length(filter.sequence)<=128 && all(x->0x30<=x<=0x3f,parameters)
                # Device replies, window operations and clipboard/title strings are never forwarded.
                valid && byte in UInt8['A','B','C','D','E','F','G','H','J','K','S','T','f','m','r','s','u','h','l'] ?
                    append!(output,filter.sequence) : (filter.discarded_bytes+=length(filter.sequence))
                empty!(filter.sequence);filter.state=:text
            elseif length(filter.sequence)>=128 || !(0x20<=byte<=0x3f)
                filter.discarded_bytes+=length(filter.sequence);empty!(filter.sequence);filter.state=:discard_csi
            end
        elseif filter.state==:discard_csi
            filter.discarded_bytes+=1
            0x40<=byte<=0x7e && (filter.state=:text)
        elseif filter.state==:string
            filter.discarded_bytes+=1
            byte==0x07 && (filter.state=:text)
            byte==0x1b && (filter.state=:string_escape)
        elseif filter.state==:string_escape
            filter.discarded_bytes+=1
            filter.state=byte==UInt8('\\') || byte==0x07 ? :text : byte==0x1b ? :string_escape : :string
        end
    end
    if final
        filter.discarded_bytes+=length(filter.sequence);empty!(filter.sequence);filter.state=:text
    end
    String(output)
end

function terminal_plain_text(text::String)
    replace(text,r"\e\[[0-?]*[ -/]*[@-~]"=>"",r"\e[78DEMc=>]"=>"")
end
