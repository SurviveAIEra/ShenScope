function restore_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing,scope=:project)
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:read,"restore",name,version)
    chosen = version
    if chosen === nothing
        pointer = analyzer_active(archive,name,ctx;authorized=true)
        pointer !== nothing || throw(ShenScopeError(:analysis,"Analyzer has no active archived version"))
        chosen = pointer["version"]
    end
    chosen isa AbstractString || throw(ShenScopeError(:analysis,"Invalid archive version"))
    archived = analyzer_read_manifest(archive,name,chosen,ctx)
    analyzer_archive_checkpoint(archive,ctx,:read,target)
    result = register_analyzer!(manager,archived.definition,ctx)
    result["restored_from"] = String(scope)
    result["validation_required"] = true
    # Archived receipts are provenance. They never become an executable session
    # validation receipt without running the current isolated worker again.
    result
end

function publish_analyzer_version!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;
        version=nothing,scope=:project,expected_pointer::Integer,operation="promote")
    !(expected_pointer isa Bool) && expected_pointer >= 0 && operation in ("promote","rollback") ||
        throw(ShenScopeError(:arguments,"Invalid analyzer publication expectation"))
    definition = lock(manager.mutex) do;deepcopy(analyzer_record!(manager,name,ctx;version).definition);end
    # Make the reviewable result concrete before persistence approval. Restore
    # and rollback use a fresh process; method tables are never rolled back.
    validation = validate_analyzer!(manager,name,ctx;version=definition.version)
    analyzer_validation_matches(definition,validation) || throw(ShenScopeError(:analysis,"Analyzer cannot be published without passing external tests"))
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:persistence,operation,name,definition.version;expected_pointer)
    pointer = store_lock(joinpath(archive.directory,".archive-transaction");
            checkpoint=()->analyzer_archive_checkpoint(archive,ctx,:persistence,target)) do
        analyzer_archive_checkpoint(archive,ctx,:persistence,target)
        previous = analyzer_active(archive,name,ctx;authorized=true)
        observed = previous === nothing ? 0 : previous["pointer_revision"]
        observed == expected_pointer || throw(ShenScopeError(:conflict,"Analyzer active pointer changed before publication"))
        lock(manager.mutex) do
            record = analyzer_record!(manager,name,ctx;version=definition.version)
            isempty(record.running) || throw(ShenScopeError(:runtime,"Finish other analyzer runs before publication"))
            analyzer_definition_verify(record.definition)
        end
        analyzer_write_manifest!(archive,definition,validation,ctx,target)
        value = Dict("name"=>definition.name,"version"=>definition.version,"source_sha256"=>definition.source_sha256,
            "scope"=>String(scope),"owner"=>archive.owner,"core_version"=>string(VERSION),
            "validated_at"=>validation["tested_at"],"external_test_suite_sha256"=>validation["external_tests"]["test_suite_sha256"],
            "external_test_count"=>length(definition.tests),"operation"=>operation,
            "previous_version"=>previous === nothing ? nothing : previous["version"])
        analyzer_archive_checkpoint(archive,ctx,:persistence,target)
        analyzer_archive_file_guard(archive.pointers.journal.path,archive.directory)
        record = version_put!(archive.pointers,name,value;expected_version=expected_pointer)
        analyzer_pointer_value(archive,name,record)
    end
    selected = lock(manager.mutex) do
        key = analyzer_record_key(ctx,definition.name,definition.version)
        haskey(manager.records,key) || return false
        manager.selected[analyzer_scope(ctx,definition.name)] = definition.version
        true
    end
    emit!(ctx,:analyzer_published,Dict("name"=>name,"version"=>definition.version,"scope"=>String(scope),
        "operation"=>operation,"pointer_revision"=>pointer["pointer_revision"]))
    Dict("pointer"=>pointer,"validation"=>validation,"session_selected"=>selected)
end

promote_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;kwargs...) =
    publish_analyzer_version!(manager,name,ctx;kwargs...,operation="promote")

function rollback_analyzer!(manager::AnalyzerManager,name::AbstractString,version::AbstractString,ctx::RuntimeContext;
        scope=:project,expected_pointer::Integer)
    restore_analyzer!(manager,name,ctx;version,scope)
    publish_analyzer_version!(manager,name,ctx;version,scope,expected_pointer,operation="rollback")
end

function analyzer_archive_history(ctx::RuntimeContext,name::AbstractString;scope=:project,limit=16)
    limit isa Integer && !(limit isa Bool) && 1 <= limit <= 16 || throw(ShenScopeError(:arguments,"Invalid analyzer history limit"))
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:read,"history",name,nothing)
    !isfile(archive.pointers.journal.path) && return Dict("name"=>name,"scope"=>String(scope),"history"=>Any[])
    analyzer_archive_file_guard(archive.pointers.journal.path,archive.directory)
    entries = version_history(archive.pointers,name;limit)
    analyzer_archive_checkpoint(archive,ctx,:read,target)
    Dict("name"=>name,"scope"=>String(scope),"history"=>[analyzer_pointer_value(archive,name,entry) for entry in entries])
end
