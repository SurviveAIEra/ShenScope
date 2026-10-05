struct ProblemsTool <: AbstractTool
    manager::ProblemManager
    projects::ProjectManager
    operations::OperationManager
end

ProblemsTool(projects=ProjectManager(); limits=ProblemLimits()) = ProblemsTool(ProblemManager(; limits),
    projects, OperationManager(; event_prefix="problems", max_running=2,
        max_result_bytes=4*1024^2, max_result_nodes=200_000))
tool_name(::ProblemsTool) = "problems"
execution_mode(::ProblemsTool) = :exclusive
tool_description(::ProblemsTool) = "Collect producer-reported project diagnostics, filter or compare owned snapshots, verify current source hashes and project them into editor Problems. Stale or inaccessible sources are withheld. Reports do not prove full-project coverage or a successful repair."

function tool_schema(::ProblemsTool)
    object_schema(Dict(
        "action" => Dict("type" => "string", "enum" => ["capture", "list", "get", "query", "compare", "source", "editor"]),
        "backend" => Dict("type" => "string", "enum" => ["tree_sitter", "go_ast", "codegraph", "typescript", "julia_syntax"]),
        "paths" => Dict("type" => "array", "minItems" => 1, "maxItems" => 512, "items" => string_schema(; max=4096)),
        "expected_revision" => integer_schema(0), "snapshot_id" => string_schema(; max=128),
        "before_id" => string_schema(; max=128), "after_id" => string_schema(; max=128),
        "item_id" => string_schema(; max=64), "include_stale" => Dict("type" => "boolean"),
        "severity" => Dict("type" => "string", "enum" => collect(PROBLEM_SEVERITIES)),
        "path" => string_schema(; max=4096), "source" => string_schema(; max=256),
        "text" => string_schema(; max=2048), "offset" => integer_schema(0, 100_000),
        "limit" => integer_schema(1, 1000), "context_lines" => integer_schema(0, 20),
        "maximum_items" => integer_schema(1, 4096)); required=["action"])
end

function problem_action_fields(arguments, required, optional)
    problem_fields(arguments, vcat(["action"], required), optional, "problem action")
end

function problem_index_state(tool::ProblemsTool, name::String, ctx::RuntimeContext)
    key = digest(ctx.root) * ":" * name
    state = lock(tool.projects.mutex) do
        get(tool.projects.states, key, nothing)
    end
    state !== nothing && return state
    authorize!(ctx, :read, "problems.cache", ctx.root; reason="Load retained diagnostic source facts")
    backend = lock(tool.projects.mutex) do
        project_backend!(tool.projects, name)
    end
    candidate = ProjectState(ctx, backend)
    isfile(candidate.journal.path) || throw(ShenScopeError(:problems, "Build this backend's project index first"))
    loaded = load_project(backend, ctx; authorized=true)
    lock(tool.projects.mutex) do
        get!(tool.projects.states, key, loaded)
    end
end

function execute(tool::ProblemsTool, arguments::AbstractDict, ctx::RuntimeContext)
    validate_tool_arguments(tool, arguments)
    action = arguments["action"]
    if action == "capture"
        problem_action_fields(arguments, ["backend"], ["paths", "expected_revision"])
        state = problem_index_state(tool, arguments["backend"], ctx)
        snapshot = capture_indexed_problems!(tool.manager, state, ctx;
            expected_revision=get(arguments, "expected_revision", nothing), paths=get(arguments, "paths", nothing))
        return Dict("snapshot_id" => snapshot.id, "snapshot_sha256" => snapshot.sha256,
            "provider" => snapshot.provider, "revision" => snapshot.revision,
            "coverage" => deepcopy(snapshot.coverage), "automatic_execution" => false)
    elseif action == "list"
        problem_action_fields(arguments, String[], ["limit"])
        return list_problem_snapshots(tool.manager, ctx; limit=get(arguments, "limit", 16))
    elseif action == "get"
        problem_action_fields(arguments, ["snapshot_id"], ["include_stale"])
        return problem_snapshot_read(tool.manager, arguments["snapshot_id"], ctx;
            include_stale=get(arguments, "include_stale", false))
    elseif action == "query"
        problem_action_fields(arguments, ["snapshot_id"], ["severity", "path", "source", "text", "offset", "limit"])
        query = ProblemQuery(; severity=get(arguments, "severity", nothing), path=get(arguments, "path", nothing),
            source=get(arguments, "source", nothing), text=get(arguments, "text", ""),
            offset=get(arguments, "offset", 0), limit=get(arguments, "limit", 100))
        return query_problem_snapshot(tool.manager, arguments["snapshot_id"], ctx; query)
    elseif action == "compare"
        problem_action_fields(arguments, ["before_id", "after_id"], ["limit"])
        return compare_problem_snapshots(tool.manager, arguments["before_id"], arguments["after_id"], ctx;
            limit=get(arguments, "limit", 256))
    elseif action == "source"
        problem_action_fields(arguments, ["snapshot_id", "item_id"], ["context_lines"])
        return read_problem_source(tool.manager, arguments["snapshot_id"], arguments["item_id"], ctx;
            context_lines=get(arguments, "context_lines", 3))
    elseif action == "editor"
        problem_action_fields(arguments, ["snapshot_id"], ["maximum_items"])
        return project_problem_editor_snapshot(tool.manager, arguments["snapshot_id"], ctx;
            maximum_items=get(arguments, "maximum_items", 2048))
    end
    throw(ShenScopeError(:problems, "Unknown project problem action"))
end
