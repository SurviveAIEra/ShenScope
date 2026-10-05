function runtime_image_launch_arguments(image::VerifiedRuntimeImage,ctx::RuntimeContext;threads=4)
    threads isa Integer && !(threads isa Bool) && 1<=threads<=64 || throw(ShenScopeError(:arguments,"Invalid image launch thread count"))
    verified=runtime_image_verify(image.receipt_path,ctx;source_root=image.source_root)
    verified.image_sha256==image.image_sha256 && verified.receipt_sha256==image.receipt_sha256 &&
        verified.source_fingerprint==image.source_fingerprint || throw(ShenScopeError(:conflict,"Verified runtime image changed before launch planning"))
    authorize!(ctx,:dynamic,"runtime.image",image.image_sha256;reason="Load the checked compiled Julia Core image into a future process")
    runtime_artifact_checkpoint(ctx;target=image.path)
    permission_decision(ctx.permissions,PermissionRequest("runtime-image-load",:dynamic,"runtime.image",image.image_sha256,"Current compiled code load permission"))==Deny &&
        throw(ShenScopeError(:permission,"Compiled runtime image load is denied"))
    Dict("arguments"=>["--startup-file=no","--threads="*string(threads),"--project="*image.source_root,"--sysimage="*image.path],
        "image_sha256"=>image.image_sha256,"source_fingerprint"=>image.source_fingerprint,
        "julia_version"=>string(image.julia_version),"machine"=>image.machine,"cpu_target"=>image.cpu_target,
        "process_started"=>false,"signature_verified"=>false,"compiled_instructions_attested"=>false,
        "note"=>"Launch separately under process authorization. This detached plan is not an atomic file-to-exec transaction.")
end

function runtime_loaded_image_view()
    pointer=Base.JLOptions().image_file
    name=pointer==C_NULL ? "" : basename(unsafe_string(pointer))
    reported=get(ENV,"SHENSCOPE_IMAGE_SOURCE_DIGEST","")
    fingerprint=occursin(r"^[0-9a-f]{64}$",reported) ? reported : nothing
    Dict("julia_version"=>string(Base.VERSION),"machine"=>string(Sys.MACHINE),"image_file"=>name,
        "image_provenance_verified"=>false,"loader_reported_source_fingerprint"=>fingerprint,
        "loader_report_is_attestation"=>false)
end
