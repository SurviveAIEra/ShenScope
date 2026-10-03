const PROJECT_NAVIGATION_ACTIONS = Set(["definitions", "references", "hover", "incoming_calls",
    "outgoing_calls", "implementations", "diagnostics"])

function project_query_integer(arguments, key, default, minimum, maximum)
    value = get(arguments, key, default)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(ShenScopeError(:graph_query, "Invalid project query limit: " * key))
    Int(value)
end

function project_query_revision(state::ProjectState, arguments)
    haskey(arguments, "revision") || return
    revision = project_query_integer(arguments, "revision", state.revision, 0, typemax(Int))
    revision == state.revision || throw(ShenScopeError(:conflict, "Project revision changed; refresh the query"))
end

function project_query_tick(ctx::RuntimeContext, index::Int=0)
    index % 256 == 0 || return
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
    yield()
end

function project_result_page(items, state::ProjectState, arguments, ctx::RuntimeContext; maximum_bytes=3 * 1024 * 1024)
    limit = project_query_integer(arguments, "limit", 50, 1, 1000)
    offset = project_query_integer(arguments, "offset", 0, 0, 1_000_000)
    selected = Dict{String,Any}[]; total = 0; bytes = 0; full = false
    for item in items
        total += 1; project_query_tick(ctx, total)
        total <= offset && continue
        full && continue
        if length(selected) >= limit; full = true; continue; end
        encoded = ncodeunits(canonical(item))
        encoded <= 1024 * 1024 || throw(ShenScopeError(:graph_query, "Project query item exceeds transport capacity"))
        if bytes + encoded > maximum_bytes
            isempty(selected) && throw(ShenScopeError(:graph_query, "Project query page cannot fit its first item"))
            full = true; continue
        end
        bytes += encoded; push!(selected, Dict{String,Any}(item))
    end
    after = offset + length(selected)
    Dict{String,Any}("revision" => state.revision, "backend" => state.backend, "total" => total,
        "offset" => offset, "next_offset" => after < total ? after : nothing,
        "items" => selected, "column_unit" => "utf8_byte")
end

function project_verify_query_config(state::ProjectState, ctx::RuntimeContext)
    compiler = get(state.metadata, "compiler", nothing)
    compiler isa AbstractDict || return
    sources = get(compiler, "configuration_sources", Any[])
    sources isa AbstractVector && length(sources) <= 32 || throw(ShenScopeError(:storage, "Invalid cached compiler source metadata"))
    for source in sources
        source isa AbstractDict && haskey(source, "path") && haskey(source, "sha256") ||
            throw(ShenScopeError(:storage, "Invalid cached compiler source identity"))
        requested = normpath(joinpath(ctx.root, source["path"]))
        path = workspace_path(ctx.root, source["path"]; must_exist=true)
        path == requested && filesize(path) <= 256 * 1024 && digest(read(path, String)) == source["sha256"] ||
            throw(ShenScopeError(:stale_index, "Compiler configuration changed; update the project index"))
    end
    if isempty(sources) && haskey(compiler, "configuration_entry")
        path = workspace_path(ctx.root, compiler["configuration_entry"])
        !ispath(path) && !islink(path) || throw(ShenScopeError(:stale_index, "Compiler configuration appeared; update the project index"))
    end
end

function project_source_map(state::ProjectState, ctx::RuntimeContext, path::AbstractString; expected_sha256=nothing)
    requested = normpath(isabspath(path) ? path : joinpath(ctx.root, path))
    absolute = workspace_path(ctx.root, path; must_exist=true)
    absolute == requested && !islink(absolute) || throw(ShenScopeError(:permission, "Project query source may not follow symlinks"))
    relative = replace(relpath(absolute, ctx.root), '\\' => '/')
    facts = get(state.files, relative, nothing)
    facts === nothing && throw(ShenScopeError(:graph_query, "Source is not in this project index"))
    if expected_sha256 !== nothing
        expected_sha256 isa AbstractString && occursin(r"^[a-f0-9]{64}$", expected_sha256) ||
            throw(ShenScopeError(:graph_query, "Invalid source digest"))
        expected_sha256 == facts.sha256 || throw(ShenScopeError(:conflict, "Requested source digest differs from the index"))
    end
    before = stat(absolute)
    before.size <= 8 * 1024 * 1024 || throw(ShenScopeError(:graph_query, "Project query source exceeds capacity"))
    text = open(input -> String(read(input, 8 * 1024 * 1024 + 1)), absolute)
    after = stat(absolute)
    (before.inode, before.device, before.size, before.mtime) == (after.inode, after.device, after.size, after.mtime) &&
        workspace_path(ctx.root, path; must_exist=true) == absolute && digest(text) == facts.sha256 ||
        throw(ShenScopeError(:stale_index, "Source changed; update the project index before navigation"))
    permission_decision(ctx.permissions, PermissionRequest("project-query-source", :read, "project.query", ctx.root, "Read indexed source")) != Deny ||
        throw(ShenScopeError(:permission, "Project source read was denied"))
    SourceMap(relative, text), facts
end

function project_symbol_selection(state::ProjectState, arguments, ctx::RuntimeContext)
    if haskey(arguments, "symbol_id")
        any(key -> haskey(arguments, key), ("file", "line", "column", "column_unit")) &&
            throw(ShenScopeError(:graph_query, "Choose a symbol ID or a source cursor"))
        value = arguments["symbol_id"]
        value isa AbstractString || throw(ShenScopeError(:graph_query, "Symbol ID must be a string"))
        id = SymbolId(value)
        haskey(state.symbols, id) || throw(ShenScopeError(:graph_query, "Symbol is not in this project index"))
        symbol = state.symbols[id]
        project_source_map(state, ctx, symbol.location.file; expected_sha256=get(arguments, "sha256", nothing))
        return SymbolId[id], nothing
    end
    path = get(arguments, "file", nothing)
    path isa AbstractString && ncodeunits(path) <= 4096 || throw(ShenScopeError(:graph_query, "A project source cursor is required"))
    source, facts = project_source_map(state, ctx, path; expected_sha256=get(arguments, "sha256", nothing))
    state.capabilities.references || throw(ShenScopeError(:capability, "This backend does not provide cursor reference resolution"))
    line = project_query_integer(arguments, "line", 1, 1, 8 * 1024 * 1024)
    column = project_query_integer(arguments, "column", 1, 1, 8 * 1024 * 1024)
    unit = get(arguments, "column_unit", "utf8_byte")
    unit in ("utf8_byte", "utf16") || throw(ShenScopeError(:graph_query, "Unsupported project cursor encoding"))
    unit == "utf16" && (column = utf16_byte_column(source, line, column - 1))
    source_byte_index(source, line, column)
    candidates = [value for value in facts.occurrences if range_contains(value.location, line, column)]
    isempty(candidates) && return SymbolId[], nothing
    sort!(candidates; by=value -> begin
        start, ending = source_range_indices(source, value.location)
        ending - start
    end)
    occurrence = first(candidates)
    copy(occurrence.targets), occurrence
end

function project_navigation_capability(state::ProjectState, action::String)
    available = action == "definitions" ? state.capabilities.definitions :
        action == "references" ? state.capabilities.references :
        action == "hover" ? state.capabilities.types :
        action == "implementations" ? state.capabilities.implementations :
        action == "diagnostics" ? state.capabilities.diagnostics : state.capabilities.calls != :none
    available || throw(ShenScopeError(:capability, "Selected backend does not support this navigation operation"))
end

function project_reference_items(state::ProjectState, ids::Vector{SymbolId}, include_declarations::Bool)
    targets = Set(ids)
    (Dict("location" => range_dict(value.location), "targets" => [id.value for id in value.targets],
        "role" => String(value.role), "write" => value.write, "indexed_source_sha256" => facts.sha256)
        for path in sort!(collect(keys(state.files))) for facts in (state.files[path],)
        for value in facts.occurrences if any(id -> id in targets, value.targets) &&
            (include_declarations || value.role != :declaration))
end

function project_call_items(state::ProjectState, ids::Vector{SymbolId}, direction::Symbol)
    adjacency = direction == :incoming ? state.reverse : state.forward
    edges = Set{String}()
    for id in ids; union!(edges, get(adjacency, id, Set{String}())); end
    (Dict("relation" => relation_dict(edge), "source" => symbol_dict(state.symbols[edge.src]),
        "target" => symbol_dict(state.symbols[edge.dst]),
        "source_sha256" => state.files[edge.location.file].sha256,
        "resolution" => startswith(edge.provenance, "compiler:") ? "compiler_static" : "syntax_candidate")
        for key in sort!(collect(edges)) for edge in (state.relations[key],) if edge.kind == :calls)
end

function project_implementation_items(state::ProjectState, ids::Vector{SymbolId}, ctx::RuntimeContext; maximum=10000)
    queue = sort!(unique(ids)); discovered = Set(queue); edges = String[]; cursor = 1
    while cursor <= length(queue)
        project_query_tick(ctx, cursor)
        current = queue[cursor]; cursor += 1
        for key in sort!(collect(get(state.reverse, current, Set{String}())))
            edge = state.relations[key]
            edge.kind in (:implements, :inherits) || continue
            push!(edges, key)
            edge.src in discovered && continue
            length(discovered) < maximum || throw(ShenScopeError(:graph_query, "Implementation traversal exceeds capacity"))
            push!(discovered, edge.src); push!(queue, edge.src)
        end
    end
    (Dict("symbol" => symbol_dict(state.symbols[edge.src]), "relation" => relation_dict(edge),
        "indexed_source_sha256" => state.files[edge.location.file].sha256)
        for key in sort!(unique(edges)) for edge in (state.relations[key],))
end

function project_diagnostic_items(state::ProjectState, arguments)
    path = get(arguments, "file", nothing)
    path === nothing || path isa AbstractString && ncodeunits(path) <= 4096 ||
        throw(ShenScopeError(:graph_query, "Invalid diagnostic file"))
    category = get(arguments, "category", nothing)
    category === nothing || category in ("error", "warning", "suggestion", "message") ||
        throw(ShenScopeError(:graph_query, "Invalid diagnostic category"))
    (merge(Dict("file" => facts.path, "indexed_source_sha256" => facts.sha256), deepcopy(item))
        for name in sort!(collect(keys(state.files))) for facts in (state.files[name],)
        if path === nothing || facts.path == path
        for item in facts.diagnostics if category === nothing || get(item, "category", nothing) == category)
end

function project_navigation(state::ProjectState, arguments::AbstractDict, ctx::RuntimeContext)
    state.root == ctx.root || throw(ShenScopeError(:permission, "Project query belongs to another workspace"))
    action = get(arguments, "action", nothing)
    action in PROJECT_NAVIGATION_ACTIONS || throw(ShenScopeError(:graph_query, "Unknown navigation action"))
    authorize!(ctx, :read, "project.query", ctx.root; reason="Read indexed semantic project evidence")
    request = PermissionRequest("project-navigation", :read, "project.query", ctx.root, "Read project facts")
    permission_decision(ctx.permissions, request) != Deny || throw(ShenScopeError(:permission, "Project reads are now denied"))
    result = lock(state.mutex) do
        project_query_tick(ctx)
        project_query_revision(state, arguments)
        project_navigation_capability(state, action)
        project_verify_query_config(state, ctx)
        if action == "diagnostics"
            haskey(arguments, "file") && project_source_map(state, ctx, arguments["file"]; expected_sha256=get(arguments, "sha256", nothing))
            return project_result_page(project_diagnostic_items(state, arguments), state, arguments, ctx)
        end
        ids, occurrence = project_symbol_selection(state, arguments, ctx)
        if action == "hover"
            type = occurrence === nothing ? isempty(ids) ? "" : get(state.symbols[first(ids)].metadata, "type", "") : occurrence.type_text
            return Dict("revision" => state.revision, "backend" => state.backend, "type" => type,
                "location" => occurrence === nothing ? nothing : range_dict(occurrence.location),
                "symbols" => [symbol_dict(state.symbols[id]) for id in ids], "column_unit" => "utf8_byte")
        elseif action == "definitions"
            return project_result_page((merge(symbol_dict(state.symbols[id]),
                Dict("indexed_source_sha256" => state.files[state.symbols[id].location.file].sha256)) for id in sort!(ids)),
                state, arguments, ctx)
        elseif action == "references"
            declarations = get(arguments, "include_declarations", true)
            declarations isa Bool || throw(ShenScopeError(:graph_query, "Declaration inclusion must be Boolean"))
            return project_result_page(project_reference_items(state, ids, declarations), state, arguments, ctx)
        elseif action in ("incoming_calls", "outgoing_calls")
            return project_result_page(project_call_items(state, ids, action == "incoming_calls" ? :incoming : :outgoing), state, arguments, ctx)
        end
        project_result_page(project_implementation_items(state, ids, ctx), state, arguments, ctx)
    end
    check_cancelled(ctx.cancellation)
    permission_decision(ctx.permissions, request) != Deny || throw(ShenScopeError(:permission, "Project reads were denied before publication"))
    result
end
