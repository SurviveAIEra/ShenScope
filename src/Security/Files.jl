function read_scoped_text(ctx::RuntimeContext, root::String, path::String, maximum::Int;
        authorized=false, tool="source.read", reason="Read a configured text source",
        size_error=:source_size, encoding_error=:source_encoding)
    0 < maximum <= 4 * 1024 * 1024 || throw(ArgumentError("Invalid text source capacity"))
    original = normpath(isabspath(path) ? path : joinpath(root, path))
    target = workspace_path(root, path; must_exist=true)
    target == original && !islink(original) || throw(ShenScopeError(:permission, "Source symlinks are not supported"))
    authorized || authorize!(ctx, :read, tool, target; reason)
    permission_decision(ctx.permissions, PermissionRequest("source-read", :read, tool, target, reason)) == Deny &&
        throw(ShenScopeError(:permission, "Source read is now denied"))
    workspace_path(root, path; must_exist=true) == target || throw(ShenScopeError(:conflict, "Source path changed after approval"))
    before = stat(target)
    before.size <= maximum || throw(ShenScopeError(size_error, "Text file exceeds the configured capacity"))
    bytes = open(target, "r") do input
        read(input, maximum + 1)
    end
    length(bytes) <= maximum || throw(ShenScopeError(size_error, "Text file exceeds the configured capacity"))
    check_cancelled(ctx.cancellation)
    after = stat(target)
    (before.inode, before.device, before.size, before.mtime) == (after.inode, after.device, after.size, after.mtime) &&
        realpath(target) == target || throw(ShenScopeError(:conflict, "Source changed while reading"))
    text = String(bytes)
    isvalid(text) || throw(ShenScopeError(encoding_error, "Text must contain valid UTF-8"))
    permission_decision(ctx.permissions, PermissionRequest("source-publish", :read, tool, target, reason)) == Deny &&
        throw(ShenScopeError(:permission,"Source read was denied before publication"))
    text
end
