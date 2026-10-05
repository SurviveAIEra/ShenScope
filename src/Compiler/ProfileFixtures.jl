struct CompilerProfileFixture{F,A<:Tuple}
    key::String
    target::CompilerTarget
    callable::F
    arguments::A
    metadata::Dict{String,Any}
end

function compiler_profile_fixture(name::AbstractString,requested="default")
    target=compiler_profile_target(name)
    requested isa String && requested in ("default","small_ascii","unicode","nested_dictionary") ||
        throw(ShenScopeError(:diagnostics,"Unknown fixed profiling fixture"))
    key=requested=="default" ? name=="canonical_dictionary" ? "nested_dictionary" : "unicode" : requested
    args=if name=="canonical_dictionary"
        key=="nested_dictionary" || throw(ShenScopeError(:diagnostics,"Canonical dictionary profiling requires its dictionary fixture"))
        (Dict{String,Any}("count"=>42,"ok"=>true,"words"=>["ShenScope","中文🙂"],
            "nested"=>Dict{String,Any}("label"=>"fixture","values"=>[1,2,3])),)
    else
        key in ("small_ascii","unicode") || throw(ShenScopeError(:diagnostics,"String profiling requires a fixed string fixture"))
        text=key=="unicode" ? repeat("ShenScope界🙂",128) : repeat("x",4096)
        name=="cliptext_string" ? (text,128) : (text,)
    end
    raw=canonical(Dict("target"=>name,"fixture"=>key,"arguments"=>Any[args...]))
    input=first(args)
    metadata=Dict{String,Any}("name"=>key,"input_kind"=>input isa String ? "string" : "dictionary",
        "input_bytes"=>input isa String ? ncodeunits(input) : ncodeunits(canonical(input)),
        "input_sha256"=>digest(raw),"user_input_accepted"=>false,
        "description"=>"deterministic installed Core fixture; not a user project workload")
    name=="cliptext_string" && (metadata["output_limit_bytes"]=128)
    CompilerProfileFixture(key,target,target.callable,args,metadata)
end

@noinline function compiler_profile_workload(fixture::CompilerProfileFixture,iterations::Int)
    checksum=0;value=""
    for _ in 1:iterations
        value=fixture.callable(fixture.arguments...)
        value isa String || throw(ShenScopeError(:diagnostics,"Fixed profiling target changed its return contract"))
        checksum=xor(checksum,ncodeunits(value))
    end
    (value=value,checksum=checksum)
end

compiler_profile_output(value)=Dict("output_sha256"=>digest(value.value),
    "output_bytes"=>ncodeunits(value.value),"checksum"=>value.checksum)
