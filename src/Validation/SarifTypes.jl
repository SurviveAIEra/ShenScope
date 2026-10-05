const SARIF_VERSION = "2.1.0"

Base.@kwdef struct SarifLimits
    maximum_report_bytes::Int = 4*1024^2
    maximum_runs::Int = 16
    maximum_results::Int = 4096
    maximum_artifacts::Int = 4096
    maximum_rules::Int = 4096
    maximum_locations_per_result::Int = 16
    maximum_message_bytes::Int = 16*1024
    maximum_base_ids::Int = 64
end

function validate_sarif_limits(limits::SarifLimits)
    4096 <= limits.maximum_report_bytes <= 8*1024^2 &&
        1 <= limits.maximum_runs <= 64 && 1 <= limits.maximum_results <= 16384 &&
        1 <= limits.maximum_artifacts <= 16384 && 1 <= limits.maximum_rules <= 16384 &&
        1 <= limits.maximum_locations_per_result <= 64 &&
        128 <= limits.maximum_message_bytes <= 64*1024 &&
        1 <= limits.maximum_base_ids <= 256 ||
        throw(ShenScopeError(:sarif, "Invalid SARIF import capacities"))
    limits
end

mutable struct SarifParseContext
    context::RuntimeContext
    sources::Dict{String,WorkspaceSourceSnapshot}
    run::Dict{String,Any}
    driver::Dict{String,Any}
    rules::Vector{Any}
    rules_by_id::Dict{String,Dict{String,Any}}
    artifacts::Vector{Any}
    producer::String
    column_kind::String
    limits::SarifLimits
    omissions::Dict{String,Int}
end

function sarif_object(value, description)
    value isa AbstractDict || throw(ShenScopeError(:sarif, description * " must be an object"))
    Dict{String,Any}(value)
end

function sarif_array(value, description, maximum)
    value isa AbstractVector && length(value) <= maximum ||
        throw(ShenScopeError(:sarif, description * " must be a bounded array"))
    value
end

function sarif_omit!(state::SarifParseContext, reason::String, count=1)
    state.omissions[reason] = get(state.omissions, reason, 0) + count
    nothing
end

function sarif_run_context(ctx, sources, value, limits)
    run = sarif_object(value, "SARIF run")
    tool = sarif_object(get(run, "tool", nothing), "SARIF tool")
    driver = sarif_object(get(tool, "driver", nothing), "SARIF tool driver")
    name = workspace_edit_text(get(driver, "name", nothing), "SARIF producer", 256)
    version = workspace_edit_text(get(driver, "semanticVersion", get(driver, "version", "")),
        "SARIF producer version", 128; empty=true)
    producer = "sarif:" * name * (isempty(version) ? "" : "@" * version)
    rules = sarif_array(get(driver, "rules", Any[]), "SARIF rules", limits.maximum_rules)
    artifacts = sarif_array(get(run, "artifacts", Any[]), "SARIF artifacts", limits.maximum_artifacts)
    bases = get(run, "originalUriBaseIds", Dict())
    bases isa AbstractDict && length(bases) <= limits.maximum_base_ids ||
        throw(ShenScopeError(:sarif, "SARIF URI base map exceeds capacity"))
    kind = get(run, "columnKind", "utf16CodeUnits")
    kind in ("utf16CodeUnits", "unicodeCodePoints") ||
        throw(ShenScopeError(:sarif, "Unsupported SARIF column encoding"))
    rule_map = sarif_rule_catalog(ctx, rules, limits)
    SarifParseContext(ctx, sources, run, driver, Any[rules...], rule_map, Any[artifacts...], producer,
        String(kind), limits, Dict())
end
