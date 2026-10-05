function sarif_message_catalog(value, limits::SarifLimits)
    table = sarif_object(value, "SARIF message catalog")
    length(table) <= 256 || throw(ShenScopeError(:capacity, "SARIF rule message catalog exceeds capacity"))
    for (name, value) in table
        workspace_edit_text(name, "SARIF catalog message ID", 256)
        item = sarif_object(value, "SARIF catalog message")
        workspace_edit_text(get(item, "text", get(item, "markdown", nothing)),
            "SARIF catalog message text", limits.maximum_message_bytes)
    end
    table
end

function sarif_rule_catalog(ctx::RuntimeContext, rules, limits::SarifLimits)
    catalog = Dict{String,Dict{String,Any}}()
    for value in rules
        workspace_source_checkpoint(ctx)
        rule = sarif_object(value, "SARIF rule descriptor")
        id = workspace_edit_text(get(rule, "id", nothing), "SARIF rule descriptor ID", 256)
        haskey(catalog, id) && throw(ShenScopeError(:sarif, "SARIF driver repeats a rule ID"))
        if haskey(rule, "name")
            workspace_edit_text(rule["name"], "SARIF rule name", 256)
        end
        if haskey(rule, "defaultConfiguration")
            configuration = sarif_object(rule["defaultConfiguration"], "SARIF default rule configuration")
            get(configuration, "level", "warning") in ("error", "warning", "note", "none") ||
                throw(ShenScopeError(:sarif, "Invalid default SARIF rule severity"))
            if haskey(configuration, "enabled")
                configuration["enabled"] isa Bool || throw(ShenScopeError(:sarif, "Invalid SARIF rule enabled flag"))
            end
        end
        if haskey(rule, "messageStrings")
            sarif_message_catalog(rule["messageStrings"], limits)
        end
        catalog[id] = rule
    end
    catalog
end

function sarif_rule_reference(state::SarifParseContext, result)
    haskey(result, "rule") || return result
    reference = sarif_object(result["rule"], "SARIF reporting descriptor reference")
    # Tool extensions have a separate rule-index namespace. Their indices
    # cannot be resolved against the driver catalog.
    haskey(reference, "toolComponent") &&
        throw(ShenScopeError(:sarif, "SARIF extension tool-component rule references are unsupported"))
    normalized = Dict{String,Any}(result)
    for (from, to) in (("id", "ruleId"), ("index", "ruleIndex"))
        haskey(reference, from) || continue
        haskey(normalized, to) && normalized[to] != reference[from] &&
            throw(ShenScopeError(:sarif, "SARIF rule reference disagrees with result identity"))
        normalized[to] = reference[from]
    end
    normalized
end

function sarif_rule_catalog_sha256(state::SarifParseContext)
    digest(bounded_canonical_json(state.rules; maximum=state.limits.maximum_report_bytes,
        max_depth=24, max_nodes=100_000))
end
