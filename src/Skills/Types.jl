const SKILL_MAX_CATALOGS = 32
const SKILL_MAX_SESSIONS = 64
const SKILL_MAX_ACTIVATIONS = 8

struct SkillConfig
    project_roots::Vector{String}
    user_roots::Vector{String}
    disabled::Set{String}
    max_entries::Int
    max_depth::Int
    max_skills::Int
    max_file_bytes::Int
    max_resource_bytes::Int
end

function skill_config(config::AbstractDict = Dict())
    section = get(config, "skills", Dict())
    fields = ("project_roots", "user_roots", "disabled", "max_entries", "max_depth", "max_skills", "max_file_bytes", "max_resource_bytes")
    section isa AbstractDict && all(key -> key in fields, keys(section)) || throw(ShenScopeError(:skill_config, "Unknown Skills configuration field"))
    roots = function (name, defaults)
        value = get(section, name, defaults)
        value isa AbstractVector && length(value) <= 16 || throw(ShenScopeError(:skill_config, "Skills roots must be a bounded list"))
        paths = String[]
        for path in value
            path isa AbstractString && !isempty(strip(path)) && ncodeunits(path) <= 4096 && !occursin('\0', path) ||
                throw(ShenScopeError(:skill_config, "Invalid Skills root"))
            name == "user_roots" && !isabspath(path) && throw(ShenScopeError(:skill_config, "User Skills roots must be absolute paths"))
            push!(paths, String(path))
        end
        length(unique(paths)) == length(paths) || throw(ShenScopeError(:skill_config, "Duplicate Skills root"))
        paths
    end
    disabled = get(section, "disabled", String[])
    disabled isa AbstractVector && length(disabled) <= 1000 && all(x -> x isa AbstractString && ncodeunits(x) <= 256, disabled) ||
        throw(ShenScopeError(:skill_config, "Invalid disabled Skills list"))
    limit = function (key, default, minimum, maximum)
        value = get(section, key, default)
        value isa Integer && !(value isa Bool) && minimum <= value <= maximum || throw(ShenScopeError(:skill_config, "Invalid Skills capacity"))
        Int(value)
    end
    SkillConfig(roots("project_roots", [".shenscope/skills", ".agents/skills", ".claude/skills"]),
        roots("user_roots", [joinpath(homedir(), ".config", "shenscope", "skills")]), Set{String}(disabled),
        limit("max_entries", 20000, 1, 100000), limit("max_depth", 8, 0, 32), limit("max_skills", 512, 1, 1000),
        limit("max_file_bytes", 64 * 1024, 1024, 1024 * 1024), limit("max_resource_bytes", 128 * 1024, 1024, 1024 * 1024))
end

struct SkillManifest
    id::String
    name::String
    description::String
    scope::Symbol
    path::String
    directory::String
    sha256::String
    metadata::Dict{String,Any}
    disable_model_invocation::Bool
    user_invocable::Bool
    allowed_tools::Union{Nothing,Vector{String}}
end

struct SkillCatalog
    root::String
    generation::Int
    manifests::Dict{String,SkillManifest}
    selected::Dict{String,String}
    order::Vector{String}
    diagnostics::Vector{Dict{String,Any}}
    entries::Int
    truncated::Bool
    loaded_at::String
end

struct SkillActivation
    manifest::SkillManifest
    arguments::String
    body::String
    loaded_at::String
end

mutable struct SkillJob
    id::String
    action::String
    context::RuntimeContext
    status::Symbol
    result::Any
    error::Union{Nothing,String}
    task::Union{Nothing,Task}
    finished_at::Float64
    result_bytes::Int
    opened::Bool
end

mutable struct SkillManager
    config::SkillConfig
    catalogs::Dict{String,SkillCatalog}
    active::Dict{Tuple{String,String},Dict{String,SkillActivation}}
    sessions::Dict{Tuple{String,String},Session}
    activation_mutexes::Dict{Tuple{String,String},ReentrantLock}
    jobs::Dict{String,SkillJob}
    mutex::ReentrantLock
    discovery_mutex::ReentrantLock
end
SkillManager(config::AbstractDict = Dict()) = SkillManager(skill_config(config), Dict{String,SkillCatalog}(),
    Dict{Tuple{String,String},Dict{String,SkillActivation}}(), Dict{Tuple{String,String},Session}(),
    Dict{Tuple{String,String},ReentrantLock}(), Dict{String,SkillJob}(), ReentrantLock(), ReentrantLock())

function skill_name(value)
    value isa AbstractString && 1 <= ncodeunits(value) <= 64 &&
        occursin(r"^[a-z0-9]+(?:-[a-z0-9]+)*$", value) || throw(ShenScopeError(:skill_name, "Skill names require lowercase letters, numbers and single hyphens"))
    String(value)
end

function skill_diagnostic(path::String, code::Symbol; severity = "error", name = nothing)
    Dict{String,Any}("path" => path, "code" => String(code), "severity" => severity, "name" => name)
end

function skill_manifest_view(manifest::SkillManifest, catalog::SkillCatalog, manager::SkillManager, ctx::RuntimeContext)
    activation = get(get(manager.active, (ctx.root, ctx.session_id), Dict()), manifest.id, nothing)
    activation !== nothing && activation.manifest.sha256 != manifest.sha256 && (activation = nothing)
    selected = get(catalog.selected, manifest.name, "") == manifest.id
    Dict("id" => manifest.id, "name" => manifest.name, "description" => manifest.description, "scope" => String(manifest.scope),
        "path" => manifest.path, "directory" => manifest.directory, "sha256" => manifest.sha256,
        "enabled" => !(manifest.id in manager.config.disabled || manifest.name in manager.config.disabled), "selected" => selected,
        "shadowed_by" => selected ? nothing : get(catalog.selected, manifest.name, nothing), "metadata" => deepcopy(manifest.metadata),
        "model_invocable" => !manifest.disable_model_invocation, "user_invocable" => manifest.user_invocable,
        "loaded" => activation !== nothing, "loaded_at" => activation === nothing ? nothing : activation.loaded_at)
end
