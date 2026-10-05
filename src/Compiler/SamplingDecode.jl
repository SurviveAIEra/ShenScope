function compiler_sampling_raw_prefix(data::AbstractVector{<:Unsigned},limits::CompilerSamplingLimits;threads=1)
    threads isa Integer && !(threads isa Bool) && 1<=threads<=64 ||
        throw(ShenScopeError(:diagnostics,"Invalid sampling buffer thread count"))
    length(data)<=limits.buffer_words*threads || throw(ShenScopeError(:capacity,"Sampling buffer exceeds its configured capacity"))
    isempty(data) || iszero(last(data)) || throw(ShenScopeError(:diagnostics,"Sampling buffer ends with an incomplete backtrace"))
    stacks=Vector{UInt}[];sizes=Int[];current=UInt[];size=0;observed=0
    for value in data
        if iszero(value)
            observed+=1
            if observed<=limits.max_samples
                push!(stacks,current);push!(sizes,size)
            end
            current=UInt[];size=0
        else
            size+=1
            observed<limits.max_samples && length(current)<COMPILER_PROFILE_MAX_STACK_SCAN && push!(current,UInt(value))
        end
    end
    (stacks=stacks,sizes=sizes,observed=observed,words=length(data))
end

function compiler_sampling_decode(prefix,lookup::AbstractDict,snapshot::RuntimeSourceSnapshot,limits::CompilerSamplingLimits)
    inventory=Dict(file.path=>file for file in snapshot.files);rows=Dict{String,Any}[]
    for (id,stack) in enumerate(prefix.stacks)
        frames=Dict{String,Any}[];seen=Set{String}();core_seen=0;scanned=0;lookup_truncated=false
        for address in stack
            values=get(lookup,address,nothing)
            values isa AbstractVector || throw(ShenScopeError(:diagnostics,"A retained sampling instruction has no resolved frame list"))
            for frame in values
                scanned+=1
                if scanned>COMPILER_SAMPLING_MAX_LOOKUP_FRAMES
                    lookup_truncated=true;break
                end
                value=compiler_profile_frame(frame,snapshot,inventory)
                value===nothing && continue
                key=canonical(value);key in seen && continue
                push!(seen,key);core_seen+=1
                length(frames)<limits.max_frames && push!(frames,value)
            end
            lookup_truncated && break
        end
        push!(rows,Dict("id"=>id,"core_frames"=>frames,"core_frames_truncated"=>core_seen>length(frames),
            "stack_scan_truncated"=>prefix.sizes[id]>COMPILER_PROFILE_MAX_STACK_SCAN,
            "lookup_scan_truncated"=>lookup_truncated))
    end
    rows
end
