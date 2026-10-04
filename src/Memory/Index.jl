function memory_build_index(snapshot::MemorySnapshot,ctx::RuntimeContext;
        max_tokens=MAX_MEMORY_INDEX_TOKENS,max_postings=MAX_MEMORY_INDEX_POSTINGS)
    all(value->value isa Integer && !(value isa Bool),(max_tokens,max_postings)) &&
        1<=max_tokens<=MAX_MEMORY_INDEX_TOKENS && 1<=max_postings<=MAX_MEMORY_INDEX_POSTINGS ||
        throw(ShenScopeError(:arguments,"Invalid memory index capacities"))
    memory_scope_id(snapshot.store,ctx)==snapshot.scope_id ||
        throw(ShenScopeError(:permission,"Memory snapshot belongs to another scope"))
    postings=Dict{String,Vector{MemoryPosting}}();lengths=NTuple{3,Int}[]
    tokens=0;posting_count=0;omitted=0;partial=Set{Int}()
    target=memory_target(snapshot.store)
    checkpoint=()->memory_checkpoint(ctx,:read,"memory.retrieve",target)
    for (document_id,document) in enumerate(snapshot.documents)
        checkpoint();counts=Dict{String,Vector{Int}}()
        spans=Dict{String,Vector{Union{Nothing,Tuple{Int,Int}}}}();sizes=zeros(Int,3)
        if !document.deleted
            fields=(String(document.value["title"]),String(document.value["content"]),join(document.value["tags"]," "))
            # Keep small metadata fields available before spending the token
            # budget on a potentially long body.
            for field in (1,3,2)
                if tokens>=max_tokens
                    !isempty(fields[field]) && (push!(partial,document_id);omitted+=1)
                    continue
                end
                result=memory_tokens(fields[field];limit=min(32768,max_tokens-tokens),checkpoint)
                (result.truncated || result.dropped_tokens>0) && push!(partial,document_id)
                omitted+=result.dropped_tokens+(result.truncated ? 1 : 0)
                tokens+=length(result.tokens);sizes[field]=length(result.tokens)
                for token in result.tokens
                    values=get!(()->zeros(Int,3),counts,token.value);values[field]+=1
                    witnesses=get!(()->Union{Nothing,Tuple{Int,Int}}[nothing,nothing,nothing],spans,token.value)
                    witnesses[field]===nothing && (witnesses[field]=(token.start_byte,token.end_byte))
                end
            end
            for term in sort!(collect(keys(counts)))
                if posting_count>=max_postings
                    omitted+=1;push!(partial,document_id);continue
                end
                values=counts[term];witnesses=spans[term]
                push!(get!(()->MemoryPosting[],postings,term),MemoryPosting(document_id,values...,
                    witnesses...));posting_count+=1
            end
        end
        push!(lengths,Tuple(sizes))
    end
    denominator=max(1,length(lengths))
    averages=ntuple(field->max(1.0,sum(row[field] for row in lengths;init=0)/denominator),3)
    checkpoint()
    MemoryLexicalIndex(snapshot,postings,lengths,averages,tokens,posting_count,omitted,partial)
end

function memory_index(manager::MemoryManager,store::MemoryStore,ctx::RuntimeContext)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Memory manager is closed"))
    end
    snapshot=memory_snapshot(store,ctx)
    cached=lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Memory manager is closed"))
        candidate=get(manager.indexes,snapshot.scope_id,nothing)
        if candidate!==nothing && candidate.snapshot.id==snapshot.id
            manager.touched[snapshot.scope_id]=time_ns();candidate
        else
            nothing
        end
    end
    cached!==nothing && return cached
    candidate=memory_build_index(snapshot,ctx)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Memory manager is closed"))
        delete!(manager.indexes,snapshot.scope_id);delete!(manager.touched,snapshot.scope_id)
        retained=sum(index.snapshot.input_bytes for index in values(manager.indexes);init=0)
        while !isempty(manager.indexes) && (length(manager.indexes)>=manager.max_indexes ||
                retained+snapshot.input_bytes>manager.max_retained_input_bytes)
            oldest=first(sort!(collect(keys(manager.indexes));by=key->(manager.touched[key],key)))
            retained-=manager.indexes[oldest].snapshot.input_bytes
            delete!(manager.indexes,oldest);delete!(manager.touched,oldest)
        end
        manager.indexes[snapshot.scope_id]=candidate;manager.touched[snapshot.scope_id]=time_ns()
    end
    candidate
end

function memory_index(store::MemoryStore,ctx::RuntimeContext)
    memory_build_index(memory_snapshot(store,ctx),ctx)
end

function memory_retire_index!(manager::MemoryManager,store::MemoryStore,ctx::RuntimeContext)
    identity=memory_scope_id(store,ctx)
    lock(manager.mutex) do
        delete!(manager.indexes,identity);delete!(manager.touched,identity)
    end
    nothing
end

function cleanup_memory!(manager::MemoryManager)
    close_operations!(manager.operations)
    lock(manager.mutex) do
        manager.closed=true;empty!(manager.indexes);empty!(manager.touched)
    end
    nothing
end
