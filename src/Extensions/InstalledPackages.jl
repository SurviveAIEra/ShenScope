const EXTENSION_LOADED_SOURCE_RECEIPTS=Dict{Base.PkgId,Dict{String,Any}}()
const EXTENSION_LOADED_SOURCE_MUTEX=ReentrantLock()

struct InstalledExtensionSpec
    name::String
    uuid::UUID
    version::VersionNumber
    entry_sha256::String
    project_sha256::String
    function InstalledExtensionSpec(name::String,uuid::UUID,version::VersionNumber,entry::String,project::String)
        occursin(r"^[A-Za-z][A-Za-z0-9_]{0,63}$",name) || throw(ShenScopeError(:extension,"Invalid Julia package name"))
        all(value->occursin(r"^[a-f0-9]{64}$",value),(entry,project)) || throw(ShenScopeError(:extension,"Installed package source hashes are required"))
        new(name,uuid,version,entry,project)
    end
end
function InstalledExtensionSpec(name::AbstractString,uuid::UUID,version::VersionNumber,entry::AbstractString,project::AbstractString)
    InstalledExtensionSpec(String(name),uuid,version,String(entry),String(project))
end

function installed_extension_files(name::AbstractString,uuid::UUID)
    occursin(r"^[A-Za-z][A-Za-z0-9_]{0,63}$",name) || throw(ShenScopeError(:extension,"Invalid Julia package name"))
    id=Base.PkgId(uuid,String(name));entry=Base.locate_package(id)
    entry===nothing && throw(ShenScopeError(:extension_package,"Package is not installed in the active Julia environment"))
    isfile(entry) && filesize(entry)<=2*1024*1024 || throw(ShenScopeError(:capacity,"Installed package entry is missing or exceeds capacity"))
    # Only the standard installed-package layout is accepted in this first loader.
    root=dirname(dirname(realpath(entry)));project=joinpath(root,"Project.toml")
    isfile(project) && filesize(project)<=65536 || throw(ShenScopeError(:extension_package,"Installed package requires a bounded Project.toml next to src"))
    id,realpath(entry),realpath(project),root
end

function installed_extension_receipt(name::AbstractString,uuid::UUID,ctx::RuntimeContext;authorized=false)
    target="package:"*String(name)*"@"*string(uuid)
    authorized || authorize!(ctx,:read,"extension.package",target;reason="Inspect installed Julia package identity and source hashes")
    extension_checkpoint(ctx;target,read=true,tool="extension.package")
    id,entry,project,root=installed_extension_files(name,uuid)
    entry_bytes=read(entry);project_bytes=read(project)
    length(entry_bytes)<=2*1024*1024 && length(project_bytes)<=65536 || throw(ShenScopeError(:capacity,"Installed package source grew beyond capacity"))
    metadata=try;TOML.parse(String(copy(project_bytes)));catch;throw(ShenScopeError(:extension_package,"Installed package has invalid project metadata"));end
    get(metadata,"name",nothing)==name && get(metadata,"uuid",nothing)==string(uuid) || throw(ShenScopeError(:extension_package,"Installed package identity does not match the requested UUID/name"))
    version=try;VersionNumber(get(metadata,"version",""));catch;throw(ShenScopeError(:extension_package,"Installed package version is missing or invalid"));end
    loaded=get(Base.loaded_modules,id,nothing)
    loaded!==nothing && realpath(Base.pathof(loaded))!=entry && throw(ShenScopeError(:conflict,"A package with this identity is already loaded from another source"))
    extension_checkpoint(ctx;target,read=true,tool="extension.package")
    prior=lock(EXTENSION_LOADED_SOURCE_MUTEX) do;get(EXTENSION_LOADED_SOURCE_RECEIPTS,id,nothing);end
    Dict("name"=>String(name),"uuid"=>string(uuid),"version"=>string(version),
        "entry_sha256"=>bytes2hex(sha256(entry_bytes)),"project_sha256"=>bytes2hex(sha256(project_bytes)),
        "entry_relative"=>replace(relpath(entry,root),'\\'=>'/'),"module_already_loaded"=>loaded!==nothing,
        "dependencies_verified"=>false,"all_package_sources_verified"=>false,"isolation"=>"trusted_in_process",
        "loaded_entry_observed_by_core"=>prior!==nothing && prior["observed_during_core_load"],"automatic_installation"=>false)
end

function load_installed_extension!(registry::ExtensionRegistry,spec::InstalledExtensionSpec,ctx::RuntimeContext)
    extension_scope!(registry,ctx)
    receipt=installed_extension_receipt(spec.name,spec.uuid,ctx)
    receipt["version"]==string(spec.version) && receipt["entry_sha256"]==spec.entry_sha256 &&
        receipt["project_sha256"]==spec.project_sha256 || throw(ShenScopeError(:conflict,"Installed extension changed after inspection"))
    id=Base.PkgId(spec.uuid,spec.name)
    prior=lock(EXTENSION_LOADED_SOURCE_MUTEX) do;get(EXTENSION_LOADED_SOURCE_RECEIPTS,id,nothing);end
    prior===nothing || all(key->prior[key]==receipt[key],("version","entry_sha256","project_sha256","entry_relative")) ||
        throw(ShenScopeError(:stale_extension_module,"Loaded Julia package differs from current source; restart Core before loading that source"))
    target="package:"*spec.name*"@"*string(spec.uuid)
    authorize!(ctx,:dynamic,"extension.lifecycle",target;reason="Load trusted installed Julia package code in Core; source entry "*spec.entry_sha256[1:12])
    # Julia's normal loader may start compiler children and write its cache.
    # This does not authorize package installation or promise module isolation.
    if Base.JLOptions().use_compiled_modules==1
        authorize!(ctx,:process,"extension.precompile",target;reason="Julia may launch compilation for this installed package")
        authorize!(ctx,:persistence,"extension.precompile",target;reason="Julia may update its compiled package cache")
    end
    extension_checkpoint(ctx;target,dynamic=true)
    current=installed_extension_receipt(spec.name,spec.uuid,ctx;authorized=true)
    all(key->current[key]==receipt[key],("version","entry_sha256","project_sha256","entry_relative")) || throw(ShenScopeError(:conflict,"Installed extension changed during authorization"))
    module_value=try;Base.require(Base.PkgId(spec.uuid,spec.name));catch;throw(ShenScopeError(:extension_load,"Installed Julia package load failed; module initialization may have effects"));end
    emit!(ctx,:extension_package_loaded,Dict("name"=>spec.name,"uuid"=>string(spec.uuid),
        "module_already_loaded"=>receipt["module_already_loaded"],"julia_methods_unloaded"=>false))
    extension_checkpoint(ctx;target,dynamic=true)
    checked=installed_extension_receipt(spec.name,spec.uuid,ctx;authorized=true)
    all(key->checked[key]==receipt[key],("version","entry_sha256","project_sha256","entry_relative")) ||
        throw(ShenScopeError(:conflict,"Extension source changed while loading; loaded Julia methods remain"))
    lock(EXTENSION_LOADED_SOURCE_MUTEX) do
        existing=get(EXTENSION_LOADED_SOURCE_RECEIPTS,id,nothing)
        existing===nothing || all(key->existing[key]==receipt[key],("version","entry_sha256","project_sha256","entry_relative")) ||
            throw(ShenScopeError(:conflict,"Concurrent Julia package source receipts disagree"))
        EXTENSION_LOADED_SOURCE_RECEIPTS[id]=merge(receipt,Dict("observed_during_core_load"=>prior===nothing ? !receipt["module_already_loaded"] : prior["observed_during_core_load"]))
    end
    isdefined(module_value,:shenscope_extension_bundle) || throw(ShenScopeError(:extension_contract,"Loaded package must export shenscope_extension_bundle()"))
    entry=getfield(module_value,:shenscope_extension_bundle)
    entry isa Function || throw(ShenScopeError(:extension_contract,"Extension bundle entry must be a function"))
    bundle=try;Base.invokelatest(entry);catch;throw(ShenScopeError(:extension_contract,"Loaded extension bundle entry failed"));end
    bundle isa ExtensionBundle && bundle.package_uuid==spec.uuid && bundle.version==spec.version ||
        throw(ShenScopeError(:extension_contract,"Loaded package bundle does not match its inspected identity/version"))
    # The load grant covers its registration, without a second Ask prompt.
    register_extension!(registry,bundle,ctx;source=receipt,authorized=true)
end
