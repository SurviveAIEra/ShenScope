const RUNTIME_IMAGE_SCHEMA = "shenscope.runtime-image/1"
const RUNTIME_SOURCE_MAX_FILES = 4096
const RUNTIME_SOURCE_MAX_FILE_BYTES = 8 * 1024^2
const RUNTIME_SOURCE_MAX_BYTES = 64 * 1024^2
const RUNTIME_IMAGE_MAX_BYTES = 2 * 1024^3
const RUNTIME_RECEIPT_MAX_BYTES = 2 * 1024^2

struct RuntimeSourceFile
    path::String
    bytes::Int
    sha256::String
    function RuntimeSourceFile(path::AbstractString,bytes::Integer,sha256::AbstractString)
        name=String(path)
        !isempty(name) && !occursin('\\',name) && !isabspath(name) &&
            all(p->p!="" && p!="." && p!="..",split(name,'/')) && ncodeunits(name)<=4096 &&
            !occursin('\0',name) || throw(ShenScopeError(:runtime_image,"Invalid runtime source path"))
        !(bytes isa Bool) && 0<=bytes<=RUNTIME_SOURCE_MAX_FILE_BYTES ||
            throw(ShenScopeError(:runtime_image,"Invalid runtime source size"))
        occursin(r"^[0-9a-f]{64}$",sha256) || throw(ShenScopeError(:runtime_image,"Invalid runtime source hash"))
        new(name,Int(bytes),String(sha256))
    end
end

struct RuntimeSourceSnapshot
    root::String
    name::String
    uuid::UUID
    version::VersionNumber
    files::Vector{RuntimeSourceFile}
    fingerprint::String
end

struct RuntimeImageReceipt
    schema::String
    image_name::String
    image_bytes::Int
    image_sha256::String
    julia_version::VersionNumber
    machine::String
    cpu_target::String
    source::RuntimeSourceSnapshot
    build_environment_sha256::String
    compiler_uuid::UUID
    compiler_version::VersionNumber
    created_at::String
end

struct VerifiedRuntimeImage
    path::String
    receipt_path::String
    receipt_sha256::String
    image_sha256::String
    source_fingerprint::String
    source_root::String
    julia_version::VersionNumber
    machine::String
    cpu_target::String
end

runtime_core_root()=dirname(dirname(@__DIR__))
runtime_source_file_view(file::RuntimeSourceFile)=Dict("path"=>file.path,"bytes"=>file.bytes,"sha256"=>file.sha256)
runtime_source_identity(snapshot::RuntimeSourceSnapshot)=Dict("name"=>snapshot.name,"uuid"=>string(snapshot.uuid),
    "version"=>string(snapshot.version),"files"=>runtime_source_file_view.(snapshot.files))
runtime_source_view(snapshot::RuntimeSourceSnapshot)=merge(runtime_source_identity(snapshot),Dict("fingerprint"=>snapshot.fingerprint))
function runtime_artifact_checkpoint(ctx::RuntimeContext;tool="runtime.image",target=ctx.root)
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    permission_decision(ctx.permissions,PermissionRequest("runtime-artifact-read",:read,tool,target,"Current runtime artifact read permission"))==Deny &&
        throw(ShenScopeError(:permission,"Runtime artifact read is denied"))
end
