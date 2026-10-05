function runtime_image_name(value::AbstractString)
    name=String(value)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$",name) && name!="." && name!=".." ||
        throw(ShenScopeError(:runtime_image,"Image receipt requires a local artifact filename"))
    name
end

function runtime_binary_identity(prefix::Vector{UInt8})
    if length(prefix)>=64 && prefix[1:4]==UInt8[0x7f,0x45,0x4c,0x46]
        prefix[5] in (1,2) && prefix[6] in (1,2) || throw(ShenScopeError(:runtime_image,"Invalid ELF identity"))
        machine=prefix[6]==1 ? Int(prefix[19])+256*Int(prefix[20]) : 256*Int(prefix[19])+Int(prefix[20])
        architecture=machine==62 ? "x86_64" : machine==183 ? "aarch64" : "unsupported"
        return Dict("format"=>"elf","architecture"=>architecture,"bits"=>prefix[5]==2 ? 64 : 32)
    end
    throw(ShenScopeError(:runtime_image,"Only checked ELF runtime images are supported in this version"))
end

function runtime_image_hash(path::String,ctx::RuntimeContext;authorized=false)
    original=normpath(abspath(path))
    !islink(original) && isfile(original) && realpath(original)==original ||
        throw(ShenScopeError(:runtime_image,"Runtime image must be a regular real file"))
    authorized || authorize!(ctx,:read,"runtime.image",original;reason="Verify runtime image bytes and binary identity")
    runtime_artifact_checkpoint(ctx;target=original)
    before=stat(original)
    64<=before.size<=RUNTIME_IMAGE_MAX_BYTES || throw(ShenScopeError(:capacity,"Runtime image size is outside supported bounds"))
    hash=SHA.SHA2_256_CTX();prefix=UInt8[];total=0
    open(original,"r") do input
        while !eof(input)
            runtime_artifact_checkpoint(ctx;target=original)
            bytes=read(input,64*1024);total+=length(bytes)
            total<=RUNTIME_IMAGE_MAX_BYTES || throw(ShenScopeError(:capacity,"Runtime image grew beyond capacity"))
            isempty(prefix) && (prefix=copy(bytes[1:min(length(bytes),64)]))
            SHA.update!(hash,bytes)
        end
    end
    after=stat(original)
    (before.device,before.inode,before.size,before.mtime)==(after.device,after.inode,after.size,after.mtime) &&
        total==before.size && !islink(original) && realpath(original)==original ||
        throw(ShenScopeError(:conflict,"Runtime image changed while hashing"))
    runtime_artifact_checkpoint(ctx;target=original)
    Dict("bytes"=>total,"sha256"=>bytes2hex(SHA.digest!(hash)),"binary"=>runtime_binary_identity(prefix))
end

function runtime_image_view(receipt::RuntimeImageReceipt)
    Dict("schema"=>receipt.schema,"image"=>Dict("name"=>receipt.image_name,"bytes"=>receipt.image_bytes,"sha256"=>receipt.image_sha256),
        "runtime"=>Dict("julia_version"=>string(receipt.julia_version),"machine"=>receipt.machine,"cpu_target"=>receipt.cpu_target),
        "source"=>runtime_source_view(receipt.source),"build"=>Dict("environment_sha256"=>receipt.build_environment_sha256,
            "compiler_uuid"=>string(receipt.compiler_uuid),"compiler_version"=>string(receipt.compiler_version)),"created_at"=>receipt.created_at)
end

function runtime_image_receipt(snapshot::RuntimeSourceSnapshot,image::String,ctx::RuntimeContext;
        build_environment_sha256::String,compiler_uuid::UUID,compiler_version::VersionNumber,cpu_target="generic")
    occursin(r"^[0-9a-f]{64}$",build_environment_sha256) || throw(ShenScopeError(:runtime_image,"Invalid build environment hash"))
    cpu_target=="generic" || throw(ShenScopeError(:runtime_image,"Only generic CPU receipts are supported in this experiment"))
    current=runtime_source_snapshot(ctx;root=snapshot.root)
    current.fingerprint==snapshot.fingerprint || throw(ShenScopeError(:conflict,"Core source changed during image compilation"))
    identity=runtime_image_hash(image,ctx)
    identity["binary"]["architecture"]==string(Sys.ARCH) && identity["binary"]["bits"]==Sys.WORD_SIZE ||
        throw(ShenScopeError(:runtime_image,"Compiled image architecture does not match this Julia runtime"))
    RuntimeImageReceipt(RUNTIME_IMAGE_SCHEMA,runtime_image_name(basename(image)),identity["bytes"],identity["sha256"],
        Base.VERSION,string(Sys.MACHINE),String(cpu_target),snapshot,build_environment_sha256,compiler_uuid,compiler_version,utcstamp())
end
