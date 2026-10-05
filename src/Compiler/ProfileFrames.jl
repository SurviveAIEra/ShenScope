function compiler_profile_frame(frame,snapshot::RuntimeSourceSnapshot,inventory)
    frame.line>0 || return nothing
    file=String(frame.file)
    isabspath(file) || return nothing
    relative=replace(relpath(normpath(file),snapshot.root),'\\'=>'/')
    startswith(relative,"src/") || return nothing
    source=get(inventory,relative,nothing)
    source===nothing && return nothing
    function_name=cliptext(String(frame.func),256)
    driver=startswith(relative,"src/Compiler/Profile") || relative=="src/Extensions/CompilerDiagnostics.jl"
    Dict("file"=>relative,"line"=>Int(frame.line),"function"=>function_name,
        "source_sha256"=>source.sha256,"inlined"=>Bool(frame.inlined),"role"=>driver ? "driver" : "core")
end

function compiler_profile_allocation_samples(allocations,snapshot,limits::CompilerProfileLimits)
    length(allocations)<=COMPILER_PROFILE_MAX_OBSERVED ||
        throw(ShenScopeError(:capacity,"Allocation profiler observed too many records"))
    inventory=Dict(file.path=>file for file in snapshot.files)
    rows=Dict{String,Any}[]
    for (id,allocation) in enumerate(Iterators.take(allocations,limits.max_samples))
        allocation.size>=0 || throw(ShenScopeError(:diagnostics,"Profiler returned a negative allocation size"))
        frames=Dict{String,Any}[];seen=Set{String}();core_seen=0
        for frame in Iterators.take(allocation.stacktrace,COMPILER_PROFILE_MAX_STACK_SCAN)
            value=compiler_profile_frame(frame,snapshot,inventory)
            value===nothing && continue
            key=canonical(value);key in seen && continue
            push!(seen,key);core_seen+=1
            length(frames)<limits.max_frames && push!(frames,value)
        end
        push!(rows,Dict("id"=>id,"type"=>cliptext(string(allocation.type),256),"bytes"=>allocation.size,
            "core_frames"=>frames,"core_frames_truncated"=>core_seen>limits.max_frames,
            "stack_scan_truncated"=>length(allocation.stacktrace)>COMPILER_PROFILE_MAX_STACK_SCAN))
    end
    rows
end

function compiler_profile_allocation_summary(rows,observed::Int,limits::CompilerProfileLimits)
    types=Dict{String,Tuple{Int,Int}}();locations=Dict{String,Tuple{Dict{String,Any},Int,Int}}()
    for row in rows
        amount,bytes=get(types,row["type"],(0,0));types[row["type"]]=(amount+1,bytes+row["bytes"])
        isempty(row["core_frames"]) && continue
        frame=first(row["core_frames"]);key=canonical(frame)
        prior,amount,bytes=get(locations,key,(frame,0,0));locations[key]=(prior,amount+1,bytes+row["bytes"])
    end
    by_type=[Dict("type"=>name,"samples"=>amount,"sampled_bytes"=>bytes) for (name,(amount,bytes)) in types]
    sort!(by_type;by=row->(-row["sampled_bytes"],row["type"]))
    by_frame=[merge(frame,Dict("samples"=>amount,"sampled_bytes"=>bytes)) for (frame,amount,bytes) in values(locations)]
    sort!(by_frame;by=row->(-row["sampled_bytes"],row["file"],row["line"],row["function"],row["inlined"]))
    Dict("observed_samples"=>observed,"retained_samples"=>length(rows),"samples_truncated"=>observed>length(rows),
        "sample_rate"=>limits.sample_rate,"retained_sampled_bytes"=>sum(row["bytes"] for row in rows;init=0),
        "samples_with_core_frames"=>count(row->!isempty(row["core_frames"]),rows),
        "core_frame_lists_truncated"=>count(row->row["core_frames_truncated"],rows),
        "stack_scans_truncated"=>count(row->row["stack_scan_truncated"],rows),
        "types"=>by_type,"top_frames"=>by_frame,
        "attribution"=>"first retained authored Core frame in each sampled allocation",
        "scope"=>"retained sampled allocation prefix; not total allocation attribution or a memory leak diagnosis",
        "instrumentation_pass_separate_from_timing"=>true,"external_paths_and_addresses_exposed"=>false)
end
