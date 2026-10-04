function analyzer_archive_inventory(archive::AnalyzerArchive,ctx::RuntimeContext;checkpoint=()->nothing)
    analyzer_archive_guard(archive,ctx)
    !isdir(archive.directory) && return (files=String[],bytes=0)
    names = readdir(archive.directory)
    length(names) <= 68 || throw(ShenScopeError(:capacity,"Analyzer archive root inventory exceeds capacity"))
    files = String[];total = 0
    for name in names
        checkpoint()
        path = joinpath(archive.directory,name)
        if name in ("pointers.jsonl","pointers.jsonl.transaction.lock",".archive-transaction.lock")
            analyzer_archive_file_guard(path,archive.directory)
            continue
        elseif name == ATOMIC_STAGING_DIRECTORY
            atomic_staging_directory(joinpath(archive.directory,"pointers.jsonl"))
            continue
        end
        analyzer_name_valid(name) && isdir(path) && !islink(path) && realpath(path) == path ||
            throw(ShenScopeError(:storage,"Unexpected analyzer archive entry"))
        versions = readdir(path)
        length(versions) <= archive.max_versions + 1 || throw(ShenScopeError(:capacity,"Analyzer version inventory exceeds capacity"))
        for version_file in versions
            checkpoint()
            version_file == ATOMIC_STAGING_DIRECTORY && (atomic_staging_directory(joinpath(path,"manifest.json"));continue)
            occursin(r"^[a-f0-9]{64}\.json$",version_file) || throw(ShenScopeError(:storage,"Unexpected analyzer version filename"))
            file = joinpath(path,version_file)
            analyzer_archive_file_guard(file,archive.directory)
            isfile(file) || throw(ShenScopeError(:storage,"Archived analyzer disappeared"))
            total += filesize(file);push!(files,file)
            length(files) <= archive.max_versions && total <= archive.max_bytes ||
                throw(ShenScopeError(:capacity,"Analyzer archive exceeds its source retention capacity"))
        end
    end
    (files=sort!(files),bytes=total)
end

function analyzer_read_manifest(archive::AnalyzerArchive,name::AbstractString,version::AbstractString,ctx::RuntimeContext)
    analyzer_archive_guard(archive,ctx)
    path = analyzer_archive_path(archive,name,version)
    analyzer_archive_file_guard(path,archive.directory)
    isfile(path) || throw(ShenScopeError(:analysis,"Archived analyzer version does not exist"))
    before = journal_file_identity(path)
    before.bytes <= min(archive.max_bytes,32 * 1024^2 + 1024 * 1024) ||
        throw(ShenScopeError(:capacity,"Archived analyzer manifest exceeds capacity"))
    raw = open(path,"r") do input;read(input,min(archive.max_bytes,33 * 1024^2)+1);end
    before == journal_file_identity(path) || throw(ShenScopeError(:conflict,"Archived analyzer changed while reading"))
    manifest = bounded_json_object(String(raw);maximum=min(archive.max_bytes,33 * 1024^2),
        max_depth=32,max_nodes=500_000,error_code=:analysis)
    Set(keys(manifest)) == Set(["format","scope","owner","definition","definition_sha256","archived_at","archived_by","validation"]) &&
        manifest["format"] === ANALYZER_ARCHIVE_FORMAT && manifest["scope"] == String(archive.scope) &&
        manifest["owner"] == archive.owner && manifest["definition"] isa AbstractDict &&
        manifest["archived_at"] isa AbstractString && manifest["archived_by"] isa AbstractString ||
        throw(ShenScopeError(:analysis,"Archived analyzer manifest fields are invalid"))
    digest(canonical(manifest["definition"])) == manifest["definition_sha256"] ||
        throw(ShenScopeError(:analysis,"Archived analyzer manifest checksum differs"))
    definition = analyzer_definition_from_dict(manifest["definition"])
    definition.name == name && definition.version == version || throw(ShenScopeError(:analysis,"Archived analyzer filename identity differs"))
    (definition=definition,manifest=manifest,path=path)
end

function analyzer_validation_matches(definition::AnalyzerDefinition,receipt)
    receipt isa AbstractDict && get(receipt,"passed",false) === true &&
        get(receipt,"selftest",false) === true && get(receipt,"version",nothing) == definition.version &&
        get(receipt,"source_sha256",nothing) == definition.source_sha256 &&
        get(receipt,"core_version",nothing) == string(VERSION) || return false
    external = get(receipt,"external_tests",nothing)
    external isa AbstractDict && get(external,"passed",false) === true &&
        get(external,"count",nothing) == length(definition.tests) && !isempty(definition.tests) &&
        get(external,"test_suite_sha256",nothing) == digest(canonical(analyzer_test_dict.(definition.tests))) || return false
    receipts = get(external,"receipts",nothing)
    receipts isa AbstractVector && length(receipts) == length(definition.tests) || return false
    for (test,observed) in zip(definition.tests,receipts)
        observed isa AbstractDict && get(observed,"passed",false) === true &&
            get(observed,"name",nothing) == test.name &&
            get(observed,"data_sha256",nothing) == digest(canonical(test.data)) &&
            get(observed,"request_sha256",nothing) == digest(canonical(test.request)) &&
            get(observed,"expected_sha256",nothing) == digest(canonical(test.expected)) &&
            get(observed,"actual_sha256",nothing) == observed["expected_sha256"] || return false
    end
    sandbox = get(receipt,"sandbox",nothing)
    sandbox isa AbstractDict && get(sandbox,"backend",nothing) == "linux-seccomp-compute-v1" &&
        all(key -> get(sandbox,key,false) === true,("enforced","thread_synchronized","no_new_privileges")) &&
        all(key -> get(sandbox,key,true) === false,("filesystem_open","filesystem_write","network","child_processes"))
end

function analyzer_write_manifest!(archive::AnalyzerArchive,definition::AnalyzerDefinition,validation,
        ctx::RuntimeContext,target::String)
    analyzer_definition_verify(definition)
    analyzer_archive_checkpoint(archive,ctx,:persistence,target)
    path = analyzer_archive_path(archive,definition.name,definition.version)
    if isfile(path) || islink(path)
        previous = analyzer_read_manifest(archive,definition.name,definition.version,ctx)
        previous.definition.version == definition.version || throw(ShenScopeError(:conflict,"Archived analyzer differs"))
        return previous
    end
    manifest = Dict("format"=>ANALYZER_ARCHIVE_FORMAT,"scope"=>String(archive.scope),"owner"=>archive.owner,
        "definition"=>analyzer_definition_dict(definition),"definition_sha256"=>digest(canonical(analyzer_definition_dict(definition))),
        "archived_at"=>utcstamp(),"archived_by"=>ctx.session_id,"validation"=>deepcopy(validation))
    content = canonical(manifest)*"\n"
    inventory = analyzer_archive_inventory(archive,ctx;checkpoint=()->analyzer_archive_checkpoint(archive,ctx,:persistence,target))
    length(inventory.files) < archive.max_versions && inventory.bytes + ncodeunits(content) <= archive.max_bytes ||
        throw(ShenScopeError(:capacity,"Analyzer archive source retention capacity reached"))
    mkpath(dirname(path));Sys.isunix() && chmod(dirname(path),0o700)
    analyzer_archive_file_guard(path,archive.directory)
    analyzer_archive_checkpoint(archive,ctx,:persistence,target)
    atomic_write(path,content)
    analyzer_read_manifest(archive,definition.name,definition.version,ctx)
end

function archive_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing,scope=:project)
    candidate = lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        (definition=deepcopy(record.definition),validation=deepcopy(record.validation))
    end
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:persistence,"archive",candidate.definition.name,candidate.definition.version)
    archived = store_lock(joinpath(archive.directory,".archive-transaction");
            checkpoint=()->analyzer_archive_checkpoint(archive,ctx,:persistence,target)) do
        analyzer_write_manifest!(archive,candidate.definition,candidate.validation,ctx,target)
    end
    Dict("name"=>name,"version"=>candidate.definition.version,"scope"=>String(scope),
        "archived"=>true,"validation_at_archive"=>analyzer_validation_matches(candidate.definition,archived.manifest["validation"]))
end
