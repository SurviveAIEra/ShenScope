function validation_bound_problem_snapshot(manager::ProjectValidationManager, report, ctx::RuntimeContext)
    snapshot = owned_problem_snapshot(manager.problems, report["problem_snapshot_id"], ctx)
    snapshot.sha256 == report["problem_snapshot_sha256"] ||
        throw(ShenScopeError(:conflict, "Validation report diagnostic receipt no longer matches"))
    snapshot
end

function inspect_validation_sources(manager::ProjectValidationManager, id::AbstractString, ctx::RuntimeContext)
    report = read_validation_report(manager, id, ctx)
    snapshot = validation_bound_problem_snapshot(manager, report, ctx)
    sources, statuses, configuration_current = problem_current_files(snapshot, ctx)
    rows = [Dict("path" => file.path, "recorded_source_sha256" => file.sha256,
        "freshness" => statuses[file.path], "current_source_sha256" => haskey(sources, file.path) ? sources[file.path].sha256 : nothing)
        for file in snapshot.files]
    workspace_source_checkpoint(ctx)
    Dict("validation_id" => report["validation_id"], "validation_sha256" => report["sha256"],
        "problem_snapshot_id" => snapshot.id, "problem_snapshot_sha256" => snapshot.sha256,
        "files" => rows, "configuration_current" => configuration_current,
        "all_selected_sources_current" => length(sources) == length(snapshot.files),
        "commands_reexecuted" => false, "outcome" => report["outcome"],
        "report_origin" => get(report, "commands_executed", true) ? "explicit_command" : "caller_import",
        "complete_project_coverage" => false)
end

function validation_command_identity(manager::ProjectValidationManager, report, ctx::RuntimeContext)
    id = get(report, "execution_run_id", nothing)
    id === nothing && return nothing
    execution = read_project_test_report(manager.testing, id, ctx)
    execution["sha256"] == report["execution_receipt_sha256"] ||
        throw(ShenScopeError(:conflict, "Validation report execution receipt no longer matches"))
    Dict("run_id" => id, "sha256" => execution["sha256"],
        "candidate" => deepcopy(execution["command"]))
end

function validation_output_configuration(report)
    family = report["family"]
    if family != "sarif"
        return Dict("format" => "command_output", "family" => family,
            "column_unit" => report["column_unit"])
    end
    runs = get(report["coverage"], "runs", nothing)
    runs isa AbstractVector && length(runs) <= 64 ||
        throw(ShenScopeError(:validation, "Retained SARIF run configuration is invalid"))
    descriptions = Dict{String,Any}[]
    for row in runs
        row isa AbstractDict && all(key -> haskey(row, key),
            ("producer", "column_kind", "driver_rules_sha256", "driver_rule_count")) ||
            throw(ShenScopeError(:validation, "Retained SARIF producer configuration is incomplete"))
        workspace_edit_hash(row["driver_rules_sha256"], "SARIF rule catalog hash")
        push!(descriptions, Dict("producer" => row["producer"], "column_kind" => row["column_kind"],
            "driver_rules_sha256" => row["driver_rules_sha256"], "driver_rule_count" => row["driver_rule_count"]))
    end
    Dict("format" => "sarif_2_1_0", "runs" => descriptions,
        "producer_identity_origin" => "untrusted_report_metadata")
end

function compare_project_validation_reports(manager::ProjectValidationManager, before_id::AbstractString,
        after_id::AbstractString, ctx::RuntimeContext; limit=256)
    before = read_validation_report(manager, before_id, ctx)
    after = read_validation_report(manager, after_id, ctx)
    old = validation_bound_problem_snapshot(manager, before, ctx)
    new = validation_bound_problem_snapshot(manager, after, ctx)
    before["family"] == after["family"] ||
        throw(ShenScopeError(:validation, "Compare checks using the same output family"))
    comparison = compare_problem_snapshots(manager.problems, old.id, new.id, ctx; limit)
    old_command = validation_command_identity(manager, before, ctx)
    new_command = validation_command_identity(manager, after, ctx)
    current = inspect_validation_sources(manager, after_id, ctx)
    old_configuration = validation_output_configuration(before)
    new_configuration = validation_output_configuration(after)
    old_versions = Dict(file.path => file.sha256 for file in old.files)
    new_versions = Dict(file.path => file.sha256 for file in new.files)
    changed = sort!([path for path in intersect(keys(old_versions), keys(new_versions))
        if old_versions[path] != new_versions[path]])
    same_command = old_command === nothing || new_command === nothing ? nothing :
        old_command["candidate"] == new_command["candidate"]
    same_specification = if old_command === nothing || new_command === nothing
        nothing
    else
        a = old_command["candidate"]; b = new_command["candidate"]
        all(key -> a[key] == b[key], ("argv", "cwd", "framework"))
    end
    result = Dict{String,Any}("schema" => "shenscope.validation-comparison/1",
        "before_validation_id" => before["validation_id"], "after_validation_id" => after["validation_id"],
        "before_validation_sha256" => before["sha256"], "after_validation_sha256" => after["sha256"],
        "before_outcome" => before["outcome"], "after_outcome" => after["outcome"],
        "diagnostic_changes" => comparison, "before_command" => old_command, "after_command" => new_command,
        "same_command_candidate" => same_command, "same_selected_source_versions" => old_versions == new_versions,
        "same_command_arguments_and_directory" => same_specification,
        "changed_selected_paths" => changed, "after_source_status" => current,
        "before_output_configuration" => old_configuration, "after_output_configuration" => new_configuration,
        "same_output_configuration" => old_configuration == new_configuration,
        "missing_report_rows_prove_repair" => false, "commands_reexecuted" => false,
        "complete_project_coverage" => false, "producer_authenticated" => false)
    workspace_source_checkpoint(ctx)
    result["sha256"] = digest(bounded_canonical_json(result; maximum=3*1024^2,
        max_depth=32, max_nodes=100_000))
    result
end
