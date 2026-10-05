function runtime_image_from_view(value::AbstractDict;source_root="")
    Set(keys(value))==Set(["schema","image","runtime","source","build","created_at"]) ||
        throw(ShenScopeError(:runtime_image,"Unknown or missing image receipt fields"))
    value["schema"]==RUNTIME_IMAGE_SCHEMA || throw(ShenScopeError(:runtime_image,"Unsupported runtime image receipt version"))
    image=value["image"];runtime=value["runtime"];build=value["build"]
    image isa AbstractDict && Set(keys(image))==Set(["name","bytes","sha256"]) &&
        runtime isa AbstractDict && Set(keys(runtime))==Set(["julia_version","machine","cpu_target"]) &&
        build isa AbstractDict && Set(keys(build))==Set(["environment_sha256","compiler_uuid","compiler_version"]) ||
        throw(ShenScopeError(:runtime_image,"Invalid image receipt sections"))
    image["name"] isa String && image["bytes"] isa Integer && !(image["bytes"] isa Bool) &&
        64<=image["bytes"]<=RUNTIME_IMAGE_MAX_BYTES && image["sha256"] isa String &&
        occursin(r"^[0-9a-f]{64}$",image["sha256"]) || throw(ShenScopeError(:runtime_image,"Invalid image receipt identity"))
    runtime["machine"] isa String && occursin(r"^[A-Za-z0-9_-]{1,128}$",runtime["machine"]) &&
        runtime["cpu_target"]=="generic" || throw(ShenScopeError(:runtime_image,"Unsupported image runtime or CPU target"))
    build["environment_sha256"] isa String && occursin(r"^[0-9a-f]{64}$",build["environment_sha256"]) ||
        throw(ShenScopeError(:runtime_image,"Invalid build environment receipt hash"))
    version=try VersionNumber(runtime["julia_version"]) catch;throw(ShenScopeError(:runtime_image,"Invalid image Julia version"));end
    compiler_uuid=try UUID(build["compiler_uuid"]) catch;throw(ShenScopeError(:runtime_image,"Invalid compiler UUID"));end
    compiler_uuid==UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d") || throw(ShenScopeError(:runtime_image,"Unknown image compiler"))
    compiler_version=try VersionNumber(build["compiler_version"]) catch;throw(ShenScopeError(:runtime_image,"Invalid compiler version"));end
    value["source"] isa AbstractDict || throw(ShenScopeError(:runtime_image,"Invalid image source receipt"))
    source=runtime_source_from_view(value["source"];root=source_root)
    value["created_at"] isa String && 1<=ncodeunits(value["created_at"])<=128 && isvalid(value["created_at"]) ||
        throw(ShenScopeError(:runtime_image,"Invalid image receipt timestamp"))
    RuntimeImageReceipt(RUNTIME_IMAGE_SCHEMA,runtime_image_name(image["name"]),Int(image["bytes"]),image["sha256"],
        version,runtime["machine"],runtime["cpu_target"],source,build["environment_sha256"],compiler_uuid,compiler_version,value["created_at"])
end

function runtime_image_inspect(receipt_path::String,ctx::RuntimeContext)
    original=normpath(abspath(receipt_path));directory=realpath(dirname(original))
    original==joinpath(directory,basename(original)) && !islink(original) ||
        throw(ShenScopeError(:runtime_image,"Image receipt must be a real file"))
    text=read_scoped_text(ctx,directory,basename(original),RUNTIME_RECEIPT_MAX_BYTES;tool="runtime.receipt")
    value=try bounded_json_object(text;maximum=RUNTIME_RECEIPT_MAX_BYTES,max_depth=16,max_nodes=65536,
        error_code=:runtime_image) catch cause
        cause isa ShenScopeError && rethrow()
        throw(ShenScopeError(:runtime_image,"Invalid image receipt JSON"))
    end
    value isa AbstractDict || throw(ShenScopeError(:runtime_image,"Image receipt object required"))
    receipt=runtime_image_from_view(value)
    Dict("receipt"=>runtime_image_view(receipt),"receipt_sha256"=>digest(text),
        "verified_image_bytes"=>false,"verified_current_source"=>false,"signature_verified"=>false)
end

function runtime_image_verify(receipt_path::String,ctx::RuntimeContext;source_root=runtime_core_root())
    view=runtime_image_inspect(receipt_path,ctx)
    receipt=runtime_image_from_view(view["receipt"];source_root=realpath(String(source_root)))
    receipt.julia_version==Base.VERSION || throw(ShenScopeError(:runtime_image_stale,"Image Julia version does not match this runtime"))
    receipt.machine==string(Sys.MACHINE) && receipt.cpu_target=="generic" ||
        throw(ShenScopeError(:runtime_image_stale,"Image platform or CPU target does not match this runtime"))
    current=runtime_source_snapshot(ctx;root=source_root)
    current.uuid==receipt.source.uuid && current.version==receipt.source.version &&
        current.fingerprint==receipt.source.fingerprint || throw(ShenScopeError(:runtime_image_stale,"Core source or dependency lock changed; rebuild this image"))
    directory=realpath(dirname(receipt_path));image=workspace_path(directory,receipt.image_name;must_exist=true)
    identity=runtime_image_hash(image,ctx)
    identity["bytes"]==receipt.image_bytes && identity["sha256"]==receipt.image_sha256 ||
        throw(ShenScopeError(:runtime_image_stale,"Runtime image bytes do not match the receipt"))
    identity["binary"]["architecture"]==string(Sys.ARCH) && identity["binary"]["bits"]==Sys.WORD_SIZE ||
        throw(ShenScopeError(:runtime_image_stale,"Runtime image binary architecture does not match"))
    # Recheck the small receipt and source inventory before returning a detached plan.
    again=runtime_image_inspect(receipt_path,ctx)
    again["receipt_sha256"]==view["receipt_sha256"] || throw(ShenScopeError(:conflict,"Image receipt changed during verification"))
    runtime_source_snapshot(ctx;root=source_root).fingerprint==current.fingerprint ||
        throw(ShenScopeError(:conflict,"Core source changed during image verification"))
    VerifiedRuntimeImage(image,realpath(receipt_path),view["receipt_sha256"],receipt.image_sha256,
        current.fingerprint,current.root,receipt.julia_version,receipt.machine,receipt.cpu_target)
end

function runtime_image_write_receipt(receipt_path::String,receipt::RuntimeImageReceipt,ctx::RuntimeContext)
    path=workspace_path(ctx.root,receipt_path)
    runtime_image_name(basename(path));dirname(path)==realpath(dirname(path)) ||
        throw(ShenScopeError(:runtime_image,"Receipt directory must be a real directory"))
    authorize!(ctx,:persistence,"runtime.receipt",path;reason="Save this runtime image build receipt")
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    value=runtime_image_view(receipt)
    # The same decoder validates authored receipts before they become launch input.
    runtime_image_from_view(value;source_root=receipt.source.root)
    text=bounded_canonical_json(value;maximum=RUNTIME_RECEIPT_MAX_BYTES)*"\n"
    image=workspace_path(dirname(path),receipt.image_name;must_exist=true)
    identity=runtime_image_hash(image,ctx)
    identity["sha256"]==receipt.image_sha256 && identity["bytes"]==receipt.image_bytes ||
        throw(ShenScopeError(:runtime_image_stale,"Image changed before receipt publication"))
    permission_decision(ctx.permissions,PermissionRequest("runtime-receipt-save",:persistence,"runtime.receipt",path,"Current image receipt permission"))==Deny &&
        throw(ShenScopeError(:permission,"Image receipt persistence is now denied"))
    atomic_write(path,text)
    Dict("path"=>replace(relpath(path,ctx.root),'\\'=>'/'),"sha256"=>digest(text),"bytes"=>ncodeunits(text))
end
