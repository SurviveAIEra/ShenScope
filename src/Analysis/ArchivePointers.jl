function analyzer_pointer_value(archive::AnalyzerArchive,name::AbstractString,record)
    record === nothing && return nothing
    value = get(record,"value",nothing)
    fields = Set(["name","version","source_sha256","scope","owner","core_version","validated_at",
        "external_test_suite_sha256","external_test_count","operation","previous_version"])
    value isa AbstractDict && Set(keys(value)) == fields && value["name"] == name &&
        value["scope"] == String(archive.scope) && value["owner"] == archive.owner &&
        value["version"] isa AbstractString && occursin(r"^[a-f0-9]{64}$",value["version"]) &&
        value["source_sha256"] isa AbstractString && occursin(r"^[a-f0-9]{64}$",value["source_sha256"]) &&
        value["external_test_suite_sha256"] isa AbstractString && occursin(r"^[a-f0-9]{64}$",value["external_test_suite_sha256"]) &&
        value["external_test_count"] isa Integer && !(value["external_test_count"] isa Bool) &&
        1 <= value["external_test_count"] <= 128 && value["operation"] in ("promote","rollback") &&
        value["core_version"] isa AbstractString && value["validated_at"] isa AbstractString &&
        (value["previous_version"] === nothing || value["previous_version"] isa AbstractString &&
            occursin(r"^[a-f0-9]{64}$",value["previous_version"])) ||
        throw(ShenScopeError(:analysis,"Archived analyzer pointer is malformed or out of scope"))
    merge(deepcopy(value),Dict("pointer_revision"=>record["version"],"updated_at"=>record["updated"]))
end

function analyzer_active(archive::AnalyzerArchive,name::AbstractString,ctx::RuntimeContext;authorized=false)
    analyzer_name_valid(name) || throw(ShenScopeError(:analysis,"Invalid analyzer name"))
    analyzer_archive_guard(archive,ctx)
    authorized || analyzer_archive_authorize!(archive,ctx,:read,"active",name,nothing)
    !isfile(archive.pointers.journal.path) && !islink(archive.pointers.journal.path) && return nothing
    analyzer_archive_file_guard(archive.pointers.journal.path,archive.directory)
    analyzer_pointer_value(archive,name,version_get(archive.pointers,name))
end

function analyzer_archive_list(ctx::RuntimeContext;scope=:project,name=nothing,offset=0,limit=50)
    offset isa Integer && !(offset isa Bool) && offset >= 0 && limit isa Integer && !(limit isa Bool) && 1 <= limit <= 100 ||
        throw(ShenScopeError(:arguments,"Invalid archive pagination"))
    name === nothing || name isa AbstractString && analyzer_name_valid(name) || throw(ShenScopeError(:analysis,"Invalid analyzer name filter"))
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:read,"versions",name,nothing)
    !isdir(archive.directory) && return Dict("scope"=>String(scope),"total"=>0,"versions"=>Any[],"next_offset"=>nothing,"offset"=>offset,"retained_bytes"=>0)
    store_lock(joinpath(archive.directory,".archive-transaction");
            checkpoint=()->analyzer_archive_checkpoint(archive,ctx,:read,target)) do
        inventory = analyzer_archive_inventory(archive,ctx;checkpoint=()->analyzer_archive_checkpoint(archive,ctx,:read,target))
        paths = name === nothing ? inventory.files : filter(path -> basename(dirname(path)) == name,inventory.files)
        selected = paths[min(offset+1,length(paths)+1):min(offset+limit,length(paths))]
        versions = Dict{String,Any}[]
        for path in selected
            analyzer_archive_checkpoint(archive,ctx,:read,target)
            candidate_name = basename(dirname(path));version = splitext(basename(path))[1]
            archived = analyzer_read_manifest(archive,candidate_name,version,ctx)
            active = analyzer_active(archive,candidate_name,ctx;authorized=true)
            push!(versions,Dict("definition"=>analyzer_definition_dict(archived.definition;include_source=false,include_tests=false),
                "scope"=>String(scope),"archived_at"=>archived.manifest["archived_at"],
                "validation_at_archive"=>analyzer_validation_matches(archived.definition,archived.manifest["validation"]),
                "active"=>active !== nothing && active["version"] == version,"pointer"=>active))
        end
        Dict("scope"=>String(scope),"total"=>length(paths),"offset"=>offset,
            "next_offset"=>offset+limit < length(paths) ? offset+limit : nothing,
            "versions"=>versions,"retained_bytes"=>inventory.bytes)
    end
end

function analyzer_archive_inspect(ctx::RuntimeContext,name::AbstractString,version::AbstractString;scope=:project)
    archive = analyzer_archive(ctx;scope)
    target = analyzer_archive_authorize!(archive,ctx,:read,"archive_inspect",name,version)
    result = analyzer_read_manifest(archive,name,version,ctx)
    analyzer_archive_checkpoint(archive,ctx,:read,target)
    Dict("definition"=>analyzer_definition_dict(result.definition),"scope"=>String(scope),
        "archived_at"=>result.manifest["archived_at"],"validation_at_archive"=>deepcopy(result.manifest["validation"]),
        "pointer"=>analyzer_active(archive,name,ctx;authorized=true))
end
