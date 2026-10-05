function sarif_rule(state::SarifParseContext, result::AbstractDict)
    result = sarif_rule_reference(state, result)
    identifier = get(result, "ruleId", nothing)
    identifier === nothing || (identifier = workspace_edit_text(identifier, "SARIF rule ID", 256))
    indexed = get(result, "ruleIndex", nothing)
    rule = nothing
    if indexed !== nothing
        index = language_integer(indexed, "SARIF rule index", 0, length(state.rules)-1)
        rule = sarif_object(state.rules[index+1], "SARIF rule")
        declared = workspace_edit_text(get(rule, "id", nothing), "indexed SARIF rule ID", 256)
        identifier === nothing || identifier == declared ||
            throw(ShenScopeError(:sarif, "SARIF rule index and ID disagree"))
        identifier = declared
    elseif identifier !== nothing
        rule = get(state.rules_by_id, identifier, nothing)
    end
    identifier, rule
end

function sarif_message(state::SarifParseContext, result::AbstractDict, rule)
    message = sarif_object(get(result, "message", nothing), "SARIF result message")
    text = get(message, "text", get(message, "markdown", nothing))
    resolved = "literal_text"
    if text === nothing
        id = workspace_edit_text(get(message, "id", nothing), "SARIF message ID", 256)
        table = rule === nothing ? Dict() : get(rule, "messageStrings", Dict())
        table isa AbstractDict || throw(ShenScopeError(:sarif, "SARIF rule message strings are invalid"))
        format = get(table, id, nothing)
        if format === nothing
            table = get(state.driver, "globalMessageStrings", Dict())
            table isa AbstractDict || throw(ShenScopeError(:sarif, "SARIF global message strings are invalid"))
            format = get(table, id, nothing)
        end
        format = sarif_object(format, "SARIF message format")
        text = get(format, "text", get(format, "markdown", nothing))
        resolved = "message_string"
    end
    raw = workspace_edit_text(text, "SARIF message", state.limits.maximum_message_bytes)
    arguments = sarif_array(get(message, "arguments", Any[]), "SARIF message arguments", 64)
    # Replace placeholders once, keeping replacement arguments literal. This
    # cannot evaluate expressions or recursively expand another argument.
    replacements = Dict("{" * string(index-1) * "}" =>
        workspace_edit_text(value, "SARIF message argument", 4096; empty=true)
        for (index, value) in enumerate(arguments))
    output = replace(raw, r"\{\d+\}" => token -> get(replacements, String(token), String(token)))
    ncodeunits(output) <= state.limits.maximum_message_bytes ||
        throw(ShenScopeError(:capacity, "Expanded SARIF message exceeds capacity"))
    output, resolved
end

function sarif_severity(result::AbstractDict, rule)
    defaults = rule === nothing ? Dict() : get(rule, "defaultConfiguration", Dict())
    defaults isa AbstractDict || throw(ShenScopeError(:sarif, "SARIF rule configuration is invalid"))
    level = get(result, "level", get(defaults, "level", "warning"))
    level in ("error", "warning", "note", "none") || throw(ShenScopeError(:sarif, "Invalid SARIF level"))
    level == "error" ? "error" : level == "warning" ? "warning" : level == "note" ? "information" : "hint"
end

function sarif_result_inactive(result::AbstractDict, state::SarifParseContext)
    baseline = get(result, "baselineState", nothing)
    baseline === nothing || baseline in ("new", "unchanged", "updated", "absent") ||
        throw(ShenScopeError(:sarif, "Invalid SARIF baseline state"))
    if baseline == "absent"
        sarif_omit!(state, "baseline_absent_results")
        return true
    end
    suppressions = sarif_array(get(result, "suppressions", Any[]), "SARIF suppressions", 64)
    for row in suppressions
        suppression = sarif_object(row, "SARIF suppression")
        kind = get(suppression, "kind", nothing)
        kind in ("inSource", "external") || throw(ShenScopeError(:sarif, "Invalid SARIF suppression kind"))
        status = get(suppression, "status", "accepted")
        status in ("accepted", "underReview", "rejected") || throw(ShenScopeError(:sarif, "Invalid SARIF suppression status"))
        if status == "accepted"
            sarif_omit!(state, "suppressed_results")
            return true
        end
    end
    false
end
