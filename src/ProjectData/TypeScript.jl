mutable struct TypeScriptSemanticBackend <: AbstractProjectDataBackend
    worker::BackendWorker
    config_path::String
end

function TypeScriptSemanticBackend(; node=get(ENV, "SHENSCOPE_NODE", "node"),
        compiler=get(ENV, "SHENSCOPE_TYPESCRIPT", joinpath(dirname(@__DIR__), "..", "editors", "node_modules", "typescript", "lib", "typescript.js")),
        config_path="tsconfig.json")
    script = normpath(joinpath(dirname(@__DIR__), "..", "scripts", "backends", "typescript_worker.mjs"))
    TypeScriptSemanticBackend(BackendWorker([String(node), "--max-old-space-size=512", script, abspath(compiler)]), String(config_path))
end

backend_capabilities(::TypeScriptSemanticBackend) = BackendCapabilities(; name="typescript",
    languages=["typescript", "tsx", "javascript"], calls=:semantic, types=true, references=true,
    inheritance=true, diagnostics=true, global_relink=true, implementations=true, rename=false)
backend_prepare!(backend::TypeScriptSemanticBackend, ctx::RuntimeContext) = worker_start!(backend.worker, ctx)
backend_close!(backend::TypeScriptSemanticBackend) = worker_close!(backend.worker)

function project_inputs(backend::TypeScriptSemanticBackend, state::ProjectState, paths, ctx::RuntimeContext; full=false)
    length(paths) <= 10000 || throw(ShenScopeError(:graph, "Changed file list exceeds capacity"))
    config = load_compiler_config(ctx; path=backend.config_path)
    available = project_paths(ctx, backend_capabilities(backend))
    roots = compiler_project_paths(ctx, config; available)
    documents = source_documents(ctx, available; maximum_bytes=24 * 1024 * 1024)
    hash = digest(canonical(Dict("version" => 1, "compiler" => "typescript@5.9.2", "configuration" => config.sha256,
        "roots" => roots, "sources" => [Dict("path" => document["path"], "sha256" => document["sha256"]) for document in documents])))
    metadata = Dict{String,Any}("compiler" => Dict("name" => "typescript", "version" => "5.9.2",
        "configuration_sha256" => config.sha256, "input_sha256" => hash,
        "configuration_sources" => deepcopy(config.sources), "configuration_entry" => config.entry, "root_count" => length(roots),
        "options" => deepcopy(config.options)), "column_unit" => "utf8_byte")
    changed = full || get(get(state.metadata, "compiler", Dict()), "input_sha256", nothing) != hash
    selected = changed ? documents : Dict{String,Any}[]
    removed = sort!(setdiff(collect(keys(state.files)), available))
    ProjectInputs(documents, selected, removed, metadata,
        Dict{String,Any}("configuration" => config, "roots" => roots, "input_sha256" => hash))
end

function project_extract_files(backend::TypeScriptSemanticBackend, inputs::ProjectInputs, ctx::RuntimeContext; full=false)
    semantic_extract_files(backend, inputs.documents, ctx, inputs.extras["configuration"],
        inputs.extras["roots"], inputs.extras["input_sha256"])
end

function extract_files(backend::TypeScriptSemanticBackend, documents, ctx::RuntimeContext;
        all_documents=documents, deleted=String[], full=false)
    config = load_compiler_config(ctx; path=backend.config_path)
    available = [String(document["path"]) for document in all_documents]
    roots = compiler_project_paths(ctx, config; available)
    hash = digest(canonical(Dict("configuration" => config.sha256, "sources" => all_documents, "roots" => roots)))
    semantic_extract_files(backend, all_documents, ctx, config, roots, hash)
end

function project_removed_files(::TypeScriptSemanticBackend, state::ProjectState, inputs::ProjectInputs, facts)
    sort!(setdiff(collect(keys(state.files)), [fact.path for fact in facts]))
end

function project_verify_inputs(backend::TypeScriptSemanticBackend, inputs::ProjectInputs, ctx::RuntimeContext)
    verify_compiler_config(inputs.extras["configuration"], ctx)
    project_paths(ctx,backend_capabilities(backend))==[document["path"] for document in inputs.documents] ||
        throw(ShenScopeError(:conflict,"Compiler source set changed during extraction"))
    for document in inputs.documents
        check_cancelled(ctx.cancellation)
        path = workspace_path(ctx.root, document["path"]; must_exist=true)
        digest(read_scoped_text(ctx,ctx.root,path,8*1024*1024;authorized=true,tool="project.index",
            size_error=:graph,encoding_error=:graph)) == document["sha256"] ||
            throw(ShenScopeError(:conflict, "Compiler input changed during semantic extraction"))
    end
end

function project_verify_removed(::TypeScriptSemanticBackend, inputs::ProjectInputs, path::String, ctx::RuntimeContext)
    # A file removed from the compiler program can still exist on disk. The
    # entire input snapshot and config are checked independently before commit.
    workspace_path(ctx.root, path)
    nothing
end

function compiler_fields(value, required::Vector{String}; optional=String[])
    value isa AbstractDict && all(key -> key in required || key in optional, keys(value)) &&
        all(key -> haskey(value, key), required) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler object has missing or unexpected fields"))
    value
end

function compiler_proto_string(value; maximum=4096, empty=false)
    value isa AbstractString && (empty || !isempty(value)) && isvalid(value) &&
        ncodeunits(value) <= maximum && !occursin('\0', value) ||
        throw(ShenScopeError(:compiler_protocol, "Compiler string violates its bounds"))
    String(value)
end

function compiler_proto_integer(value, minimum::Int, maximum::Int)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:compiler_protocol, "Compiler integer violates its bounds"))
    Int(value)
end

function compiler_proto_array(value, maximum::Int)
    value isa AbstractVector && length(value) <= maximum ||
        throw(ShenScopeError(:compiler_protocol, "Compiler array violates its bounds"))
    value
end

function compiler_endpoint(value, symbols::Dict{Tuple{String,String},CodeSymbol}, owner=nothing)
    compiler_fields(value, ["path", "key"])
    path = compiler_proto_string(value["path"])
    owner === nothing || path == owner || throw(ShenScopeError(:compiler_protocol, "Compiler edge source escapes its file"))
    key = compiler_proto_string(value["key"])
    get(symbols, (path, key), nothing) === nothing && throw(ShenScopeError(:compiler_protocol, "Compiler endpoint has no declared symbol"))
    symbols[(path, key)].id
end

const COMPILER_SYMBOL_KINDS = Set([:function, :method, :class, :interface, :type, :enum, :enum_member,
    :module, :parameter, :property, :variable, :import])
const COMPILER_RELATION_PROVENANCE = Dict("references" => "typescript_symbol", "calls" => "typescript_signature",
    "inherits" => "typescript_heritage", "implements" => "typescript_heritage", "imports" => "typescript_module")

function compiler_result_facts(raw, documents, config::CompilerConfig, roots::Vector{String}, input_sha256::String)
    compiler_fields(raw, ["version", "compiler", "compiler_version", "input_sha256", "config_sha256", "files", "statistics"])
    raw["version"] === 1 && raw["compiler"] == "typescript" && raw["compiler_version"] == "5.9.2" &&
        raw["input_sha256"] == input_sha256 && raw["config_sha256"] == config.sha256 ||
        throw(ShenScopeError(:compiler_protocol, "Compiler version or input snapshot identity changed"))
    supplied = Dict(String(document["path"]) => document for document in documents)
    length(supplied) == length(documents) || throw(ShenScopeError(:compiler_protocol, "Compiler source list has duplicate paths"))
    maps = Dict{String,SourceMap}()
    frames = Dict{String,Any}()
    symbols = Dict{Tuple{String,String},CodeSymbol}()
    buckets = Dict{String,Vector{CodeSymbol}}()
    statistics = Dict("declarations" => 0, "occurrences" => 0, "relations" => 0)
    for frame in compiler_proto_array(raw["files"], 10000)
        compiler_fields(frame, ["path", "sha256", "symbols", "edges", "occurrences", "diagnostics", "unresolved_calls", "external_calls"])
        path = compiler_proto_string(frame["path"])
        haskey(supplied, path) && !haskey(frames, path) && supplied[path]["sha256"] == frame["sha256"] ||
            throw(ShenScopeError(:compiler_protocol, "Compiler file is foreign, duplicate or stale"))
        frames[path] = frame
        source = SourceMap(path, supplied[path]["source"]); maps[path] = source
        root_range = SourceRange(path, 1, length(source.starts); end_column=source.ends[end]-source.starts[end]+1)
        root = CodeSymbol(symbol_id(path, "file"), :file, basename(path), path, root_range,
            Symbol(supplied[path]["language"]), Dict{String,Any}("semantic" => true, "compiler" => "typescript@5.9.2"))
        symbols[(path, "__file__")] = root; buckets[path] = CodeSymbol[root]
        for declaration in compiler_proto_array(frame["symbols"], 100000)
            compiler_fields(declaration, ["key", "kind", "name", "qualified_name", "range", "selection", "type", "signature", "parent_key"])
            key = compiler_proto_string(declaration["key"])
            key != "__file__" && !haskey(symbols, (path, key)) || throw(ShenScopeError(:compiler_protocol, "Compiler symbol key collides"))
            kind = Symbol(compiler_proto_string(declaration["kind"]; maximum=32))
            kind in COMPILER_SYMBOL_KINDS || throw(ShenScopeError(:compiler_protocol, "Compiler symbol kind is unsupported"))
            name = compiler_proto_string(declaration["name"]; maximum=1024)
            qualified = compiler_proto_string(declaration["qualified_name"])
            location = compiler_range(source, declaration["range"]); selection = compiler_range(source, declaration["selection"])
            range_encloses(location, selection) && !isempty(source_range_text(source, selection)) ||
                throw(ShenScopeError(:compiler_protocol, "Compiler declaration selection is outside its source range"))
            metadata = Dict{String,Any}("semantic" => true, "compiler" => "typescript@5.9.2",
                "selection" => range_dict(selection), "type" => compiler_proto_string(declaration["type"]; empty=true),
                "signature" => compiler_proto_string(declaration["signature"]; empty=true))
            symbol = CodeSymbol(symbol_id("typescript", path, key), kind, name, qualified, location,
                Symbol(supplied[path]["language"]), metadata)
            symbols[(path, key)] = symbol; push!(buckets[path], symbol)
            statistics["declarations"] += 1
        end
    end
    all(path -> haskey(frames, path), roots) || throw(ShenScopeError(:compiler_protocol, "Compiler omitted a declared root file"))
    result = FileFacts[]
    for path in sort!(collect(keys(frames)))
        frame = frames[path]; source = maps[path]
        edges = Dict{String,Relation}()
        for declaration in frame["symbols"]
            parent_key = compiler_proto_string(declaration["parent_key"])
            haskey(symbols, (path, parent_key)) || throw(ShenScopeError(:compiler_protocol, "Compiler declaration has no parent"))
            parent = symbols[(path, parent_key)]; symbol = symbols[(path, declaration["key"])]
            parent.id != symbol.id && range_encloses(parent.location, symbol.location) ||
                throw(ShenScopeError(:compiler_protocol, "Compiler declaration parent is cyclic or has a foreign range"))
            relation = Relation(parent.id, symbol.id, :contains, symbol.location; provenance="typescript_declaration")
            edges[relation.id] = relation
        end
        for item in compiler_proto_array(frame["edges"], 200000)
            compiler_fields(item, ["src", "dst", "kind", "range", "provenance"])
            kind = compiler_proto_string(item["kind"]; maximum=32)
            get(COMPILER_RELATION_PROVENANCE, kind, nothing) == item["provenance"] ||
                throw(ShenScopeError(:compiler_protocol, "Compiler relation provenance is inconsistent"))
            src = compiler_endpoint(item["src"], symbols, path); dst = compiler_endpoint(item["dst"], symbols)
            location = compiler_range(source, item["range"])
            relation = Relation(src, dst, Symbol(kind), location; confidence=1.0, provenance="compiler:typescript@5.9.2:" * item["provenance"])
            edges[relation.id] = relation; statistics["relations"] += 1
        end
        occurrences = SymbolOccurrence[]
        for item in compiler_proto_array(frame["occurrences"], 200000)
            compiler_fields(item, ["range", "targets", "role", "type", "write"])
            targets = [compiler_endpoint(value, symbols) for value in compiler_proto_array(item["targets"], 16)]
            location = compiler_range(source, item["range"])
            item["write"] isa Bool || throw(ShenScopeError(:compiler_protocol, "Compiler write marker must be Boolean"))
            role = Symbol(compiler_proto_string(item["role"]; maximum=32))
            text = compiler_proto_string(item["type"]; empty=true)
            occurrence = SymbolOccurrence(location, targets, role, text, item["write"])
            push!(occurrences, occurrence); statistics["occurrences"] += 1
        end
        diagnostics = Dict{String,Any}[]
        for item in compiler_proto_array(frame["diagnostics"], 10000)
            compiler_fields(item, ["code", "category", "message", "range"])
            category = compiler_proto_string(item["category"]; maximum=32)
            category in ("error", "warning", "suggestion", "message") || throw(ShenScopeError(:compiler_protocol, "Compiler diagnostic category is invalid"))
            push!(diagnostics, Dict("code" => compiler_proto_integer(item["code"], 0, 1_000_000),
                "category" => category, "message" => compiler_proto_string(item["message"]),
                "location" => range_dict(compiler_range(source, item["range"])), "source" => "typescript@5.9.2"))
        end
        metadata = Dict{String,Any}("semantic" => true, "compiler" => "typescript@5.9.2",
            "configuration_sha256" => config.sha256,
            "unresolved_calls" => compiler_proto_integer(frame["unresolved_calls"], 0, 200000),
            "external_calls" => compiler_proto_integer(frame["external_calls"], 0, 200000), "root" => path in roots)
        sort!(occurrences; by=value -> (value.location.start_line, value.location.start_column, value.location.end_line, value.location.end_column, String(value.role)))
        push!(result, FileFacts(path, supplied[path]["sha256"], sort!(buckets[path]; by=value -> value.id.value),
            sort!(collect(values(edges)); by=value -> value.id), CallReference[], diagnostics, occurrences, metadata))
    end
    compiler_fields(raw["statistics"], ["declarations", "occurrences", "relations", "library_bytes"])
    for (key, count) in statistics
        compiler_proto_integer(raw["statistics"][key], 0, 400000) == count ||
            throw(ShenScopeError(:compiler_protocol, "Compiler reported inconsistent output counts"))
    end
    compiler_proto_integer(raw["statistics"]["library_bytes"], 0, 32 * 1024 * 1024)
    result
end

function semantic_extract_files(backend::TypeScriptSemanticBackend, documents, ctx::RuntimeContext,
        config::CompilerConfig, roots::Vector{String}, input_sha256::String)
    raw = worker_request(backend.worker, "semantic", Dict("version" => 1, "root" => ctx.root,
        "documents" => documents, "roots" => roots, "options" => config.options,
        "config_sha256" => config.sha256, "input_sha256" => input_sha256), ctx)
    compiler_result_facts(raw, documents, config, roots, input_sha256)
end
