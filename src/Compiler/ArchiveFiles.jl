function compiler_archive_scope(store::CompilerArchiveStore,ctx::RuntimeContext)
    expected=compiler_archive_store(ctx;limits=store.limits)
    store.directory==expected.directory && store.workspace==expected.workspace && store.session_id==expected.session_id ||
        throw(ShenScopeError(:permission,"Compiler archive belongs to another conversation or workspace"))
    nothing
end

function compiler_archive_path(store::CompilerArchiveStore,name::String,ctx::RuntimeContext)
    compiler_archive_scope(store,ctx)
    name in ("index.json","index.json.lock") || occursin(r"^[0-9a-f]{64}\.json$",name) ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler archive filename"))
    path=joinpath(store.directory,name);memory_path_guard(path,ctx);path
end

function compiler_archive_checkpoint(store::CompilerArchiveStore,ctx::RuntimeContext,category::Symbol)
    compiler_archive_scope(store,ctx);check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    for required in unique([:read,category])
        permission_decision(ctx.permissions,PermissionRequest("compiler-archive-current",required,"compiler.archive",
            compiler_archive_target(store),"Current compiler archive permission"))==Deny &&
            throw(ShenScopeError(:permission,"Compiler archive permission was revoked"))
    end
    yield();nothing
end

function compiler_archive_authorize(store::CompilerArchiveStore,ctx::RuntimeContext,category::Symbol)
    compiler_archive_scope(store,ctx)
    authorize!(ctx,:read,"compiler.archive",compiler_archive_target(store);reason="Read owned compiler evidence")
    category==:read || authorize!(ctx,category,"compiler.archive",compiler_archive_target(store);
        reason="Persist owned compiler report metadata and bounded evidence")
    compiler_archive_checkpoint(store,ctx,category)
end

function compiler_archive_read_file(store::CompilerArchiveStore,name::String,ctx::RuntimeContext,maximum::Int;
        category=:read)
    compiler_archive_checkpoint(store,ctx,category)
    path=compiler_archive_path(store,name,ctx);before=journal_file_identity(path)
    before===nothing && throw(ShenScopeError(:conflict,"Referenced compiler archive evidence is missing"))
    before.bytes<=maximum || throw(ShenScopeError(:capacity,"Compiler archive evidence exceeds capacity"))
    text=try
        open(path,"r") do io
            raw=read(io,maximum+1)
            length(raw)<=maximum && isvalid(String(copy(raw))) ||
                throw(ShenScopeError(:diagnostics,"Compiler archive evidence exceeds capacity or has invalid UTF-8"))
            String(raw)
        end
    catch error
        error isa ShenScopeError && rethrow()
        throw(ShenScopeError(:conflict,"Unable to read compiler archive evidence"))
    end
    compiler_archive_checkpoint(store,ctx,category)
    journal_file_identity(compiler_archive_path(store,name,ctx))==before ||
        throw(ShenScopeError(:conflict,"Compiler archive evidence changed during reading"))
    text
end

function compiler_archive_disk_inventory(store::CompilerArchiveStore,ctx::RuntimeContext;category=:read)
    compiler_archive_path(store,"index.json",ctx);compiler_archive_checkpoint(store,ctx,category)
    isdir(store.directory) || return Dict("assets"=>Dict{String,Int}(),"asset_bytes"=>0,"staging_bytes"=>0)
    names=readdir(store.directory)
    length(names)<=store.limits.max_reports+64 || throw(ShenScopeError(:capacity,"Compiler archive directory exceeds its entry bound"))
    assets=Dict{String,Int}();staging_bytes=0
    for name in names
        compiler_archive_checkpoint(store,ctx,category)
        if name==ATOMIC_STAGING_DIRECTORY
            path=atomic_staging_directory(compiler_archive_index_path(store))
            staged=readdir(path)
            length(staged)<=2*(store.limits.max_reports+32) ||
                throw(ShenScopeError(:capacity,"Compiler archive staging inventory exceeds capacity"))
            for temporary in staged
                compiler_archive_checkpoint(store,ctx,category)
                file=joinpath(path,temporary)
                isfile(file) && !islink(file) && realpath(file)==file ||
                    throw(ShenScopeError(:permission,"Compiler archive staging entry is invalid"))
                bytes=filesize(file)
                bytes<=COMPILER_ARCHIVE_ASSET_BYTES || throw(ShenScopeError(:capacity,"Compiler archive staging file exceeds capacity"))
                staging_bytes+=bytes
            end
        elseif name in ("index.json","index.json.lock")
            compiler_archive_path(store,name,ctx)
        elseif occursin(r"^[0-9a-f]{64}\.json$",name)
            path=compiler_archive_path(store,name,ctx);bytes=filesize(path)
            bytes<=COMPILER_ARCHIVE_ASSET_BYTES || throw(ShenScopeError(:capacity,"Compiler archive asset exceeds capacity"))
            assets[chop(name;tail=5)]=Int(bytes)
        else
            throw(ShenScopeError(:diagnostics,"Compiler archive directory contains an unknown entry"))
        end
    end
    Dict("assets"=>assets,"asset_bytes"=>sum(values(assets);init=0),"staging_bytes"=>staging_bytes)
end

function compiler_archive_write_file(store::CompilerArchiveStore,name::String,text::String,ctx::RuntimeContext;
        maximum,guard=()->nothing)
    path=compiler_archive_path(store,name,ctx)
    ncodeunits(text)<=maximum || throw(ShenScopeError(:capacity,"Compiler archive publication exceeds capacity"))
    atomic_stream_write(path;maximum_bytes=maximum,before_publish=(bytes,result)->begin
        compiler_archive_checkpoint(store,ctx,:persistence);compiler_archive_path(store,name,ctx);guard();true
    end) do output
        write(output,text)
    end
end
