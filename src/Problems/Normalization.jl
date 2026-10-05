function problem_severity(value)
    value isa AbstractString || throw(ShenScopeError(:problems, "Invalid problem severity"))
    value == "suggestion" && return "hint"
    value == "message" && return "information"
    value in PROBLEM_SEVERITIES || throw(ShenScopeError(:problems, "Invalid problem severity"))
    String(value)
end

function problem_code(value)
    value === nothing && return nothing
    value isa Integer && !(value isa Bool) && -2^31 <= value <= 2^31-1 && return Int(value)
    problem_text(value, "problem code", 256)
end

function problem_location(value, source::SourceMap)
    value === nothing && return nothing
    problem_fields(value, ["file", "start_line", "end_line"],
        ["start_column", "end_column", "column_unit"], "problem source range")
    value["file"] == source.path && get(value, "column_unit", "utf8_byte") == "utf8_byte" ||
        throw(ShenScopeError(:problems, "Problem range has a different file or encoding"))
    first_line = problem_integer(value["start_line"], "problem start line", 1, length(source.starts))
    last_line = problem_integer(value["end_line"], "problem end line", first_line, length(source.starts))
    first_column = problem_integer(get(value, "start_column", 1), "problem start column", 1, 8*1024^2)
    last_column = problem_integer(get(value, "end_column", 1), "problem end column", 1, 8*1024^2)
    location = SourceRange(source.path, first_line, last_line; start_column=first_column, end_column=last_column)
    source_range_indices(source, location)
    location
end

function project_problem(snapshot::WorkspaceSourceSnapshot, severity, message;
        source="", code=nothing, location=nothing, tags=String[], semantic=false,
        metadata=Dict{String,Any}(), limits=ProblemLimits())
    validate_problem_limits(limits)
    level = problem_severity(severity)
    text = problem_text(message, "problem message", limits.maximum_message_bytes)
    origin = problem_text(source, "problem producer", 256; empty=true)
    number = problem_code(code)
    semantic isa Bool || throw(ShenScopeError(:problems, "Problem semantic flag must be boolean"))
    tags isa AbstractVector && length(tags) <= 2 && all(tag -> tag in ("unnecessary", "deprecated"), tags) &&
        length(unique(tags)) == length(tags) || throw(ShenScopeError(:problems, "Invalid problem tags"))
    position = location isa SourceRange ? location : problem_location(location, snapshot.source)
    position === nothing || position.file == snapshot.path ||
        throw(ShenScopeError(:problems, "Problem location is outside its source"))
    position === nothing || source_range_indices(snapshot.source, position)
    metadata isa AbstractDict || throw(ShenScopeError(:problems, "Problem metadata must be an object"))
    bounded_canonical_json(metadata; maximum=4096, max_depth=8, max_nodes=256)
    identity = Dict("path" => snapshot.path, "severity" => level, "message" => text,
        "source" => origin, "code" => number,
        "location" => position === nothing ? nothing : range_dict(position), "tags" => sort(String.(tags)))
    ProjectProblem(digest(canonical(identity)), snapshot.path, snapshot.sha256, level, text, origin,
        number, position, sort(String.(tags)), semantic, deepcopy(Dict{String,Any}(metadata)))
end

function normalize_indexed_problem(value, snapshot::WorkspaceSourceSnapshot; limits=ProblemLimits())
    problem_fields(value, ["category", "message"],
        ["code", "location", "source", "semantic", "incomplete_tag"], "indexed diagnostic")
    metadata = Dict{String,Any}()
    if haskey(value, "incomplete_tag")
        metadata["incomplete_tag"] = problem_text(value["incomplete_tag"], "incomplete syntax tag", 128; empty=true)
    end
    project_problem(snapshot, value["category"], value["message"];
        source=get(value, "source", ""), code=get(value, "code", nothing),
        location=get(value, "location", nothing),
        semantic=get(value, "semantic", startswith(get(value, "source", ""), "typescript@")), metadata, limits)
end

function problem_dict(problem::ProjectProblem)
    Dict("id" => problem.id, "path" => problem.path, "source_sha256" => problem.source_sha256,
        "severity" => problem.severity, "message" => problem.message, "source" => problem.source,
        "code" => problem.code, "location" => problem.location === nothing ? nothing : range_dict(problem.location),
        "tags" => copy(problem.tags), "semantic" => problem.semantic, "metadata" => deepcopy(problem.metadata))
end

function problem_file_dict(file::ProblemFileReport)
    Dict("path" => file.path, "source_sha256" => file.sha256, "items" => problem_dict.(file.items),
        "reported_items" => file.reported_items, "omitted_items" => file.omitted_items,
        "status" => file.status, "document_version" => file.version)
end

function problem_sort_key(problem::ProjectProblem)
    location = problem.location
    (problem.path, findfirst(==(problem.severity), PROBLEM_SEVERITIES),
        location === nothing ? 0 : location.start_line,
        location === nothing ? 0 : location.start_column, problem.id)
end

function problem_file_report(snapshot::WorkspaceSourceSnapshot, items::Vector{ProjectProblem};
        reported_items=length(items), omitted_items=0, version=nothing, status="reported")
    reported_items = problem_integer(reported_items, "reported problem count", 0, 1_000_000)
    omitted_items = problem_integer(omitted_items, "omitted problem count", 0, reported_items)
    length(items) + omitted_items <= reported_items ||
        throw(ShenScopeError(:problems, "Problem counts exceed the producer report"))
    version === nothing || (version = problem_integer(version, "document version", 0, 2^31-1))
    status in ("reported", "limited", "no_diagnostic_capability") ||
        throw(ShenScopeError(:problems, "Invalid problem file status"))
    all(item -> item.path == snapshot.path && item.source_sha256 == snapshot.sha256, items) ||
        throw(ShenScopeError(:problems, "Problem items have mixed source versions"))
    unique_items = Dict(item.id => item for item in items)
    selected = sort!(collect(values(unique_items)); by=problem_sort_key)
    ProblemFileReport(snapshot.path, snapshot.sha256, selected, reported_items, omitted_items, status, version)
end
