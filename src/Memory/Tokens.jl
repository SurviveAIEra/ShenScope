function memory_tokens(text::AbstractString;limit=32768,max_term_bytes=128,checkpoint=()->nothing)
    isvalid(text) || throw(ShenScopeError(:memory,"Memory text must be valid UTF-8"))
    limit isa Integer && !(limit isa Bool) && 1<=limit<=MAX_MEMORY_INDEX_TOKENS ||
        throw(ArgumentError("Invalid memory token capacity"))
    max_term_bytes isa Integer && !(max_term_bytes isa Bool) && 1<=max_term_bytes<=512 ||
        throw(ArgumentError("Invalid memory token byte capacity"))
    tokens=MemoryToken[];dropped=0;truncated=false;latin_start=0;previous_han=0
    function emit_token!(start,stop)
        start==0 && return
        if stop-start>max_term_bytes
            dropped+=1;return
        end
        term=lowercase(String(SubString(text,start,prevind(text,stop))))
        ncodeunits(term)<=max_term_bytes || (dropped+=1;return)
        if length(tokens)>=limit
            truncated=true;return
        end
        push!(tokens,MemoryToken(term,start,stop))
    end
    scanned=0
    for index in eachindex(text)
        scanned+=1
        scanned%1024==0 && checkpoint()
        char=text[index];stop=nextind(text,index)
        if is_han(char)
            if latin_start!=0;emit_token!(latin_start,index);latin_start=0;end
            emit_token!(index,stop)
            previous_han!=0 && emit_token!(previous_han,stop)
            previous_han=index
        elseif isletter(char) || isnumeric(char) || char=='_'
            previous_han=0
            latin_start==0 && (latin_start=index)
        else
            previous_han=0
            if latin_start!=0;emit_token!(latin_start,index);latin_start=0;end
        end
        truncated && break
    end
    !truncated && latin_start!=0 && emit_token!(latin_start,ncodeunits(text)+1)
    checkpoint()
    (;tokens,truncated,dropped_tokens=dropped)
end

function memory_query(text::AbstractString)
    isvalid(text) && ncodeunits(text)<=MAX_MEMORY_QUERY_BYTES ||
        throw(ShenScopeError(:arguments,"Memory query exceeds its UTF-8 capacity"))
    optional=String[];required=String[];excluded=String[];phrases=String[];excluded_phrases=String[]
    index=firstindex(text)
    while index<=lastindex(text)
        while index<=lastindex(text) && isspace(text[index]);index=nextind(text,index);end
        index>lastindex(text) && break
        mode=:optional
        if text[index] in ('+','-')
            mode=text[index]=='+' ? :required : :excluded;index=nextind(text,index)
            index<=lastindex(text) && !isspace(text[index]) ||
                throw(ShenScopeError(:arguments,"A query prefix requires a term or quoted phrase"))
        end
        quoted=text[index]=='"';buffer=IOBuffer()
        if quoted
            index=nextind(text,index);closed=false
            while index<=lastindex(text)
                char=text[index];index=nextind(text,index)
                if char=='"';closed=true;break;end
                if char=='\\'
                    index<=lastindex(text) && text[index] in ('"','\\') ||
                        throw(ShenScopeError(:arguments,"Quoted queries only escape quotes and backslashes"))
                    char=text[index];index=nextind(text,index)
                end
                write(buffer,char)
            end
            closed || throw(ShenScopeError(:arguments,"Memory query contains an unterminated phrase"))
            index>lastindex(text) || isspace(text[index]) ||
                throw(ShenScopeError(:arguments,"Quoted query phrases must be separated by whitespace"))
        else
            while index<=lastindex(text) && !isspace(text[index])
                text[index]!='"' || throw(ShenScopeError(:arguments,"A quote must start a query phrase"))
                write(buffer,text[index]);index=nextind(text,index)
            end
        end
        raw=strip(String(take!(buffer)))
        isempty(raw) && throw(ShenScopeError(:arguments,"Memory query phrases cannot be empty"))
        result=memory_tokens(raw;limit=MAX_MEMORY_QUERY_TERMS+1)
        !result.truncated && result.dropped_tokens==0 ||
            throw(ShenScopeError(:arguments,"Memory query contains too many or oversized terms"))
        terms=unique(token.value for token in result.tokens)
        isempty(terms) && throw(ShenScopeError(:arguments,"Memory query requires letters, numbers or Han characters"))
        destination=mode==:excluded ? excluded : mode==:required ? required : optional
        !(quoted && mode==:excluded) && append!(destination,terms)
        if quoted
            push!(mode==:excluded ? excluded_phrases : phrases,lowercase(raw))
        end
        length(unique(vcat(optional,required,excluded)))<=MAX_MEMORY_QUERY_TERMS &&
            length(phrases)+length(excluded_phrases)<=16 ||
            throw(ShenScopeError(:arguments,"Memory query exceeds its term or phrase capacity"))
    end
    MemoryQuery(String(text),Tuple(unique(optional)),Tuple(unique(required)),Tuple(unique(excluded)),
        Tuple(unique(phrases)),Tuple(unique(excluded_phrases)))
end
