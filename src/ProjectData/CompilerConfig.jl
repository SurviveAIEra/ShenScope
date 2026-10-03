struct CompilerConfig
    options::Dict{String,Any}
    includes::Vector{String}
    excludes::Vector{String}
    files::Union{Nothing,Vector{String}}
    sources::Vector{Dict{String,Any}}
    sha256::String
    entry::String
end

const COMPILER_BOOLEAN_OPTIONS = Set(["strict", "strictNullChecks", "strictFunctionTypes",
    "strictBindCallApply", "strictPropertyInitialization", "noImplicitAny", "noImplicitThis",
    "alwaysStrict", "useUnknownInCatchVariables", "allowJs", "checkJs", "skipLibCheck",
    "esModuleInterop", "allowSyntheticDefaultImports", "forceConsistentCasingInFileNames",
    "noUncheckedIndexedAccess", "exactOptionalPropertyTypes", "noUnusedLocals",
    "noUnusedParameters", "noImplicitReturns", "noFallthroughCasesInSwitch", "noEmit",
    "resolveJsonModule", "allowImportingTsExtensions", "verbatimModuleSyntax",
    "isolatedModules", "experimentalDecorators", "emitDecoratorMetadata", "removeComments",
    "allowUnreachableCode", "allowUnusedLabels", "noPropertyAccessFromIndexSignature"])
const COMPILER_ENUM_OPTIONS = Dict(
    "target" => Set(["ES5", "ES6", "ES2015", "ES2016", "ES2017", "ES2018", "ES2019", "ES2020", "ES2021", "ES2022", "ES2023", "ES2024", "ESNEXT"]),
    "module" => Set(["NONE", "COMMONJS", "AMD", "UMD", "SYSTEM", "ES6", "ES2015", "ES2020", "ES2022", "ESNEXT", "NODE16", "NODE18", "NODE20", "NODENEXT", "PRESERVE"]),
    "moduleResolution" => Set(["CLASSIC", "NODE", "NODE10", "NODE16", "NODENEXT", "BUNDLER"]),
    "jsx" => Set(["PRESERVE", "REACT", "REACT-NATIVE", "REACT-JSX", "REACT-JSXDEV"]),
    "moduleDetection" => Set(["AUTO", "LEGACY", "FORCE"]))

function compiler_string(value; maximum=4096, label="value")
    value isa AbstractString && !isempty(value) && isvalid(value) && ncodeunits(value) <= maximum &&
        !any(character -> character in ('\0', '\r', '\n'), value) ||
        throw(ShenScopeError(:compiler_config, "Invalid compiler " * label))
    String(value)
end

function compiler_strings(value; maximum=128, string_bytes=512, label="list")
    value isa AbstractVector && length(value) <= maximum ||
        throw(ShenScopeError(:compiler_config, "Compiler " * label * " exceeds capacity"))
    result = [compiler_string(item; maximum=string_bytes, label) for item in value]
    length(unique(result)) == length(result) || throw(ShenScopeError(:compiler_config, "Duplicate compiler " * label * " entry"))
    result
end

function compiler_path(ctx::RuntimeContext, value::AbstractString; base=ctx.root, must_exist=false)
    value = replace(compiler_string(value; label="path"), '\\' => '/')
    requested = normpath(isabspath(value) ? value : joinpath(base, value))
    target = workspace_path(ctx.root, requested; must_exist)
    # normpath can retain a trailing separator after a directory '..'.
    relpath(target, requested) == "." || throw(ShenScopeError(:compiler_config, "Compiler paths may not follow symlinks"))
    replace(relpath(target, ctx.root), '\\' => '/')
end

function compiler_pattern(ctx::RuntimeContext, value::AbstractString, directory::String)
    pattern = compiler_path(ctx, value; base=directory)
    count(==('*'), pattern) <= 16 && count(==('?'), pattern) <= 16 && !occursin('[', pattern) &&
        !occursin(']', pattern) && !occursin('{', pattern) && !occursin('}', pattern) ||
        throw(ShenScopeError(:compiler_config, "Unsupported or excessive compiler glob"))
    if !occursin('*', pattern) && !occursin('?', pattern) && !haskey(SOURCE_LANGUAGES, lowercase(splitext(pattern)[2]))
        pattern = pattern == "." ? "**" : pattern * "/**"
    end
    pattern
end

function compiler_segment_match(pattern::String, value::String)
    characters = collect(value); prior = falses(length(characters) + 1); prior[1] = true
    for token in pattern
        next = falses(length(prior))
        token == '*' && (next[1] = prior[1])
        for index in eachindex(characters)
            next[index + 1] = token == '*' ? prior[index + 1] || next[index] :
                prior[index] && (token == '?' || token == characters[index])
        end
        prior = next
    end
    prior[end]
end

function compiler_glob_match(pattern::AbstractString, path::AbstractString)
    parts = split(Sys.iswindows() ? lowercase(pattern) : pattern, '/'; keepempty=false)
    names = split(Sys.iswindows() ? lowercase(path) : path, '/'; keepempty=false)
    length(parts) <= 128 && length(names) <= 128 || throw(ShenScopeError(:compiler_config, "Compiler glob path is too deep"))
    prior = falses(length(names) + 1); prior[1] = true
    for part in parts
        next = falses(length(prior))
        part == "**" && (next[1] = prior[1])
        for index in eachindex(names)
            next[index + 1] = part == "**" ? prior[index + 1] || next[index] :
                prior[index] && compiler_segment_match(String(part), String(names[index]))
        end
        prior = next
    end
    prior[end]
end

function normalize_compiler_options(document, ctx::RuntimeContext, directory::String)
    document isa AbstractDict && length(document) <= 96 ||
        throw(ShenScopeError(:compiler_config, "Compiler options must be a bounded object"))
    options = Dict{String,Any}()
    for (key, value) in document
        if key in COMPILER_BOOLEAN_OPTIONS
            value isa Bool || throw(ShenScopeError(:compiler_config, "Compiler Boolean option has the wrong type: " * key))
            value === true && key in ("emitDecoratorMetadata", "resolveJsonModule") &&
                throw(ShenScopeError(:compiler_config, "Compiler option requires a currently unsupported analysis path: " * key))
            options[key] = value
        elseif haskey(COMPILER_ENUM_OPTIONS, key)
            text = compiler_string(value; maximum=64, label="option")
            uppercase(text) in COMPILER_ENUM_OPTIONS[key] || throw(ShenScopeError(:compiler_config, "Unknown compiler option value: " * key))
            options[key] = text
        elseif key == "baseUrl"
            relative = compiler_path(ctx, compiler_string(value; label="base URL"); base=directory)
            options[key] = normpath(joinpath(ctx.root, relative))
        elseif key == "paths"
            value isa AbstractDict && length(value) <= 64 || throw(ShenScopeError(:compiler_config, "Compiler aliases exceed capacity"))
            aliases = Dict{String,Any}()
            for (name, targets) in value
                name = compiler_string(name; maximum=256, label="alias")
                !isabspath(name) && count(==('*'), name) <= 1 || throw(ShenScopeError(:compiler_config, "Invalid compiler alias"))
                aliases[name] = compiler_strings(targets; maximum=16, label="alias targets")
            end
            options[key] = aliases
        elseif key == "lib"
            libraries = compiler_strings(value; maximum=32, string_bytes=64, label="libraries")
            all(name -> occursin(r"^[A-Za-z0-9.]+$", name), libraries) || throw(ShenScopeError(:compiler_config, "Invalid compiler library name"))
            options[key] = libraries
        elseif key == "types"
            values = compiler_strings(value; maximum=32, label="ambient types")
            isempty(values) || throw(ShenScopeError(:compiler_config, "External ambient type packages are not loaded by this backend"))
            options[key] = values
        else
            throw(ShenScopeError(:compiler_config, "Unsupported compiler option: " * String(key)))
        end
    end
    options
end

function load_compiler_config(ctx::RuntimeContext; path="tsconfig.json")
    sources = Dict{String,Any}[]; active = Set{String}(); loaded = Dict{String,Dict{String,Any}}()
    function visit(relative::String, depth::Int)
        depth <= 8 && length(loaded) + length(active) < 32 ||
            throw(ShenScopeError(:compiler_config, "Compiler inheritance exceeds capacity"))
        relative in active && throw(ShenScopeError(:compiler_config, "Compiler configuration inheritance contains a cycle"))
        haskey(loaded, relative) && return deepcopy(loaded[relative])
        local absolute = joinpath(ctx.root, relative); push!(active, relative)
        text = read_scoped_text(ctx, ctx.root, absolute, 256 * 1024; tool="project.compiler_config",
            reason="Read compiler analysis configuration", size_error=:compiler_config, encoding_error=:compiler_config)
        local document = compiler_jsonc(text)
        allowed = Set(["compilerOptions", "extends", "include", "exclude", "files", "references", "\$schema"])
        all(key -> key in allowed, keys(document)) || throw(ShenScopeError(:compiler_config, "Unsupported compiler configuration field"))
        references = get(document, "references", Any[])
        references isa AbstractVector && isempty(references) ||
            throw(ShenScopeError(:compiler_config, "Multi-project compiler references are not supported yet"))
        directory = dirname(absolute)
        result = Dict{String,Any}("options" => Dict{String,Any}())
        ancestors = get(document, "extends", Any[])
        ancestors isa AbstractString && (ancestors = [ancestors])
        ancestors = compiler_strings(ancestors; maximum=8, label="extends")
        for value in ancestors
            (startswith(value, ".") || isabspath(value)) ||
                throw(ShenScopeError(:compiler_config, "Compiler package inheritance is not supported; use a workspace-relative file"))
            endswith(lowercase(value), ".json") || (value *= ".json")
            parent = compiler_path(ctx, value; base=directory, must_exist=true)
            inherited = visit(parent, depth + 1)
            merge!(result["options"], inherited["options"])
            haskey(inherited["options"],"paths") && (result["paths_directory"]=inherited["paths_directory"])
            for key in ("include", "exclude", "files"); haskey(inherited, key) && (result[key] = inherited[key]); end
        end
        merge!(result["options"], normalize_compiler_options(get(document, "compilerOptions", Dict()), ctx, directory))
        haskey(get(document,"compilerOptions",Dict()),"paths") && (result["paths_directory"]=directory)
        for key in ("include", "exclude")
            haskey(document, key) || continue
            result[key] = [compiler_pattern(ctx, value, directory) for value in compiler_strings(document[key]; label=key)]
        end
        if haskey(document, "files")
            result["files"] = [compiler_path(ctx, value; base=directory, must_exist=true) for value in compiler_strings(document["files"]; maximum=10000, label="files")]
        end
        push!(sources, Dict("path" => relative, "sha256" => digest(text)))
        delete!(active, relative); loaded[relative] = deepcopy(result)
        result
    end
    relative = compiler_path(ctx, path)
    absolute = joinpath(ctx.root, relative)
    ispath(absolute) && !isfile(absolute) && throw(ShenScopeError(:compiler_config, "Compiler configuration must be a regular file"))
    document = isfile(absolute) ? visit(relative, 1) : Dict{String,Any}("options" => Dict())
    islink(absolute) && throw(ShenScopeError(:compiler_config, "Compiler configuration may not be a symlink"))
    options = merge(Dict{String,Any}("target" => "ES2022", "module" => "ESNext", "moduleResolution" => "Bundler",
        "strict" => true, "skipLibCheck" => true, "allowJs" => true, "checkJs" => true, "jsx" => "Preserve", "types" => Any[]), document["options"])
    options["noEmit"] = true
    if haskey(options,"paths")
        base=get(options,"baseUrl",document["paths_directory"])
        for (name,targets) in options["paths"]
            options["paths"][name]=[normpath(joinpath(ctx.root,compiler_path(ctx,target;base))) for target in targets]
        end
    end
    includes = get(document, "include", haskey(document, "files") ? String[] : ["**"]); excludes = get(document, "exclude", String[])
    files = get(document, "files", nothing)
    sort!(sources; by=value -> value["path"])
    hash = digest(canonical(Dict("version" => 1, "options" => options, "include" => includes,
        "exclude" => excludes, "files" => files, "sources" => sources)))
    CompilerConfig(options, includes, excludes, files, sources, hash, relative)
end

function compiler_project_paths(ctx::RuntimeContext, config::CompilerConfig; available=project_paths(ctx, BackendCapabilities(; name="typescript", languages=["typescript", "tsx", "javascript"])))
    config.files === nothing || all(path -> path in available, config.files) ||
        throw(ShenScopeError(:compiler_config, "Explicit compiler files must be supported workspace source files"))
    selected = config.files === nothing ? String[] : copy(config.files)
    for path in available
        any(pattern -> compiler_glob_match(pattern, path), config.includes) || continue
        any(pattern -> compiler_glob_match(pattern, path), config.excludes) && continue
        get(config.options, "allowJs", true) || !(get(SOURCE_LANGUAGES, lowercase(splitext(path)[2]), "") == "javascript") || continue
        push!(selected, path)
    end
    sort!(unique(selected))
end

function verify_compiler_config(config::CompilerConfig, ctx::RuntimeContext)
    for source in config.sources
        path = joinpath(ctx.root, compiler_path(ctx, source["path"]; must_exist=true))
        filesize(path) <= 256 * 1024 && digest(read(path, String)) == source["sha256"] ||
            throw(ShenScopeError(:conflict, "Compiler configuration changed during extraction"))
    end
    isempty(config.sources) && (ispath(joinpath(ctx.root, config.entry)) || islink(joinpath(ctx.root, config.entry))) &&
        throw(ShenScopeError(:conflict, "Compiler configuration appeared during extraction"))
    nothing
end
