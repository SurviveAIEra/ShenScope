function julia_query_guard(state::ProjectState, ctx::RuntimeContext, arguments)
    state.root == ctx.root || throw(ShenScopeError(:permission, "Julia project belongs to another workspace"))
    state.backend == "julia_syntax" || throw(ShenScopeError(:capability, "Select the Julia syntax backend for this query"))
    authorize!(ctx, :read, "project.query", ctx.root; reason="Read indexed Julia method evidence")
    project_query_tick(ctx)
    project_query_revision(state, arguments)
end

function julia_query_read_checkpoint(ctx::RuntimeContext)
    request = PermissionRequest("julia-query", :read, "project.query", ctx.root, "Read Julia facts")
    permission_decision(ctx.permissions, request) != Deny || throw(ShenScopeError(:permission, "Julia project reads were revoked"))
    project_query_tick(ctx)
end

function julia_method_matches(symbol::CodeSymbol, arguments)
    symbol.kind == :method && return julia_symbol_filters(symbol, arguments)
    false
end

function julia_symbol_filters(symbol::CodeSymbol, arguments)
    path = get(arguments, "file", nothing)
    query = get(arguments, "query", "")
    path === nothing || path isa AbstractString || throw(ShenScopeError(:graph_query, "Julia file filter must be text"))
    query isa AbstractString && ncodeunits(query) <= 4096 || throw(ShenScopeError(:graph_query, "Invalid Julia method filter"))
    (path === nothing || symbol.location.file == path) &&
        (isempty(query) || occursin(lowercase(query), lowercase(symbol.qualified_name)))
end

function julia_verify_selected_sources(state, symbols, ctx, arguments)
    for path in sort!(unique([symbol.location.file for symbol in symbols]))
        julia_query_read_checkpoint(ctx)
        project_source_map(state, ctx, path; expected_sha256=get(arguments, "sha256", nothing))
    end
end

function julia_method_item(state, symbol::CodeSymbol)
    merge(symbol_dict(symbol), Dict("indexed_source_sha256" => state.files[symbol.location.file].sha256,
        "evidence_kind" => "julia_syntax_declaration", "compiler_confirmed" => false,
        "selected_runtime_method" => false))
end

function julia_arity_overlap(a::AbstractDict, b::AbstractDict)
    low = max(a["minimum_arity"], b["minimum_arity"])
    high_a = a["maximum_arity"]; high_b = b["maximum_arity"]
    high = high_a === nothing ? high_b : high_b === nothing ? high_a : min(high_a, high_b)
    Dict("overlap" => high === nothing || low <= high, "minimum" => low, "maximum" => high)
end

function julia_annotation_pattern(parameter::AbstractDict)
    # This is a textual pattern, not subtype evaluation. Even a familiar name
    # such as Number can be shadowed by project code.
    canonical(parameter["annotation_identity"])
end

function julia_dispatch_pair(a::CodeSymbol, b::CodeSymbol)
    left = a.metadata; right = b.metadata
    overlap = julia_arity_overlap(left, right)
    overlap["overlap"] || return nothing
    pa = left["positional"]; pb = right["positional"]
    exact = canonical(left["dispatch_identity"]) == canonical(right["dispatch_identity"])
    axes = Dict{String,Any}[]; a_specific = false; b_specific = false; unknown = false
    for index in 1:min(length(pa), length(pb))
        ta = julia_annotation_pattern(pa[index]); tb = julia_annotation_pattern(pb[index])
        pattern = if ta == tb
            "same_annotation"
        elseif ta == canonical(Any["Identifier", "Any"])
            b_specific = true; "left_unannotated_or_any"
        elseif tb == canonical(Any["Identifier", "Any"])
            a_specific = true; "right_unannotated_or_any"
        else
            unknown = true; "different_annotations_unresolved"
        end
        push!(axes, Dict("position" => index, "left" => pa[index]["annotation"],
            "right" => pb[index]["annotation"], "pattern" => pattern))
    end
    crossed = a_specific && b_specific
    classification = exact ? "same_syntax_signature" : crossed ? "crossed_annotation_pattern" :
        unknown ? "unresolved_type_overlap" : "arity_overlap"
    Dict("left" => a.id.value, "right" => b.id.value, "classification" => classification,
        "arity" => overlap, "axes" => axes, "compiler_confirmed" => false,
        "runtime_ambiguity" => nothing, "runtime_overwrite" => nothing,
        "requires_runtime_confirmation" => true,
        "evidence" => [range_dict(a.location), range_dict(b.location)])
end

function julia_dispatch_groups(state::ProjectState, methods, ctx, arguments)
    maximum = project_query_integer(arguments, "max_pairs", 10_000, 1, 20_000)
    groups = Dict{String,Vector{CodeSymbol}}()
    for symbol in methods
        push!(get!(Vector{CodeSymbol}, groups, symbol.qualified_name), symbol)
    end
    # Account for all pairs before allocating results; omit no hidden suffix.
    pair_count = sum(length(members) * (length(members) - 1) ÷ 2 for members in values(groups); init=0)
    pair_count <= maximum || throw(ShenScopeError(:graph_query, "Julia dispatch pair budget exceeded; narrow the method filter"))
    results = Dict{String,Any}[]; checked = 0
    for name in sort!(collect(keys(groups)))
        members = sort!(groups[name]; by=symbol -> (symbol.location.file, symbol.location.start_line, symbol.id.value))
        pairs = Dict{String,Any}[]
        for first in eachindex(members), second in (first+1):length(members)
            checked += 1
            checked % 64 == 0 && julia_query_read_checkpoint(ctx)
            pair = julia_dispatch_pair(members[first], members[second])
            pair === nothing || push!(pairs, pair)
        end
        push!(results, Dict("name" => name, "method_count" => length(members),
            "methods" => [julia_method_item(state, symbol) for symbol in members],
            "pairs" => pairs, "pairs_considered" => length(members) * (length(members)-1) ÷ 2,
            "compiler_confirmed" => false, "evidence_kind" => "syntax_dispatch_patterns",
            "limitations" => ["types_not_evaluated", "imports_not_resolved", "world_age_not_observed",
                "generated_methods_not_materialized", "keywords_do_not_select_positional_dispatch",
                "cross_file_modules_with_same_name_may_be_distinct"]))
    end
    results
end

function julia_structure_items(state, arguments, ctx)
    path = get(arguments, "file", nothing); query = get(arguments, "query", "")
    path === nothing || path isa AbstractString || throw(ShenScopeError(:graph_query, "Invalid Julia structure path"))
    query isa AbstractString || throw(ShenScopeError(:graph_query, "Invalid Julia structure filter"))
    result = Dict{String,Any}[]
    for name in sort!(collect(keys(state.files)))
        path === nothing || name == path || continue
        isempty(query) || occursin(lowercase(query), lowercase(name)) || continue
        facts = state.files[name]
        julia_query_read_checkpoint(ctx)
        project_source_map(state, ctx, name; expected_sha256=get(arguments, "sha256", nothing))
        push!(result, Dict("file" => name, "indexed_source_sha256" => facts.sha256,
            "declarations" => [symbol_dict(symbol) for symbol in facts.symbols if symbol.kind != :file],
            "calls" => deepcopy(get(facts.metadata, "julia_calls", Any[])),
            "imports" => deepcopy(get(facts.metadata, "julia_imports", Any[])),
            "includes" => deepcopy(get(facts.metadata, "julia_includes", Any[])),
            "exports" => deepcopy(get(facts.metadata, "julia_exports", Any[])),
            "parse_complete" => get(facts.metadata, "parse_complete", false),
            "diagnostics" => deepcopy(facts.diagnostics), "source_evaluated" => false,
            "compiler_confirmed" => false))
    end
    result
end

function julia_project_query(state::ProjectState, arguments::AbstractDict, ctx::RuntimeContext)
    action = get(arguments, "action", "")
    action in JULIA_PROJECT_ACTIONS || throw(ShenScopeError(:graph_query, "Unknown Julia project query"))
    julia_query_guard(state, ctx, arguments)
    result = lock(state.mutex) do
        project_query_revision(state, arguments)
        julia_query_read_checkpoint(ctx)
        items = if action == "julia_structure"
            julia_structure_items(state, arguments, ctx)
        else
            methods = CodeSymbol[]
            for (index, id) in enumerate(sort!(collect(keys(state.symbols))))
                index % 256 == 0 && julia_query_read_checkpoint(ctx)
                symbol = state.symbols[id]
                julia_method_matches(symbol, arguments) && push!(methods, symbol)
            end
            julia_verify_selected_sources(state, methods, ctx, arguments)
            action == "julia_dispatch" ? julia_dispatch_groups(state, methods, ctx, arguments) :
                [julia_method_item(state, symbol) for symbol in methods]
        end
        page = project_result_page(items, state, arguments, ctx)
        page["evidence_kind"] = "julia_syntax"
        page["compiler_confirmed"] = false
        page["source_evaluated"] = false
        page
    end
    julia_query_read_checkpoint(ctx)
    result
end
