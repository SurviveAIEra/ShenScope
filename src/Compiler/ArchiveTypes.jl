const COMPILER_ARCHIVE_SCHEMA="shenscope.compiler-archive/1"
const COMPILER_ARCHIVE_INDEX_BYTES=512*1024
const COMPILER_ARCHIVE_ASSET_BYTES=COMPILER_IR_MAX_BYTES+1024*1024

struct CompilerArchiveLimits
    max_reports::Int
    max_total_bytes::Int
    function CompilerArchiveLimits(;max_reports=128,max_total_bytes=64*1024^2)
        max_reports isa Integer && !(max_reports isa Bool) && 1<=max_reports<=512 &&
            max_total_bytes isa Integer && !(max_total_bytes isa Bool) &&
            1024<=max_total_bytes<=256*1024^2 || throw(ShenScopeError(:capacity,"Invalid compiler archive limits"))
        new(Int(max_reports),Int(max_total_bytes))
    end
end

struct CompilerArchiveStore
    directory::String
    workspace::String
    session_id::String
    limits::CompilerArchiveLimits
end

function compiler_archive_store(ctx::RuntimeContext;limits=CompilerArchiveLimits())
    owner=valid_id(ctx.session_id);workspace=digest(ctx.root)
    directory=joinpath(normpath(abspath(ctx.state_dir)),"compiler-reports",workspace,owner)
    CompilerArchiveStore(directory,workspace,owner,limits)
end

compiler_archive_owner(store::CompilerArchiveStore)=Dict("workspace"=>store.workspace,"session_id"=>store.session_id)
compiler_archive_target(store::CompilerArchiveStore)="session:"*store.session_id*":compiler-reports"
compiler_archive_index_path(store::CompilerArchiveStore)=joinpath(store.directory,"index.json")

function compiler_archive_hash(value,name="report digest")
    value isa String && occursin(r"^[0-9a-f]{64}$",value) ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler archive "*name))
    value
end

function compiler_archive_revision(value)
    compiler_ir_integer(value,"archive revision",0,typemax(Int)-1)
end

function compiler_archive_timestamp(value)
    text=compiler_ir_text(value,"archive timestamp",64)
    endswith(text,"Z") && tryparse(DateTime,chop(text;tail=1))!==nothing ||
        throw(ShenScopeError(:diagnostics,"Invalid UTC compiler archive timestamp"))
    text
end

function compiler_archive_limits(report::AbstractDict)
    fields=string.(fieldnames(CompilerIRLimits))
    value=get(report,"limits",nothing);compiler_ir_fields(value,fields,"archived compiler limits")
    CompilerIRLimits(;[Symbol(key)=>value[key] for key in fields]...)
end

function compiler_archive_empty_index(store::CompilerArchiveStore)
    index=Dict{String,Any}("schema"=>COMPILER_ARCHIVE_SCHEMA,"owner"=>compiler_archive_owner(store),
        "revision"=>0,"reports"=>Any[])
    index["index_sha256"]=digest(canonical(index));index
end
