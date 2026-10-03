const MCP_SCHEMA_ANNOTATIONS = Set(["title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "\$comment", "\$id", "\$schema", "format"])
const MCP_SCHEMA_ASSERTIONS = Set(["type", "enum", "const", "properties", "patternProperties", "additionalProperties", "required",
    "minProperties", "maxProperties", "propertyNames", "dependentRequired", "dependentSchemas", "dependencies",
    "items", "prefixItems", "additionalItems", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "pattern",
    "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "\$ref", "\$defs", "definitions"])
const MCP_SCHEMA_TYPES = Set(["object", "array", "string", "number", "integer", "boolean", "null"])

function mcp_pattern(expression::AbstractString)
    ncodeunits(expression) <= 2048 || throw(ShenScopeError(:mcp_schema, "Schema regular expression exceeds capacity"))
    try
        Regex("(*LIMIT_MATCH=100000)(*LIMIT_DEPTH=1000)" * expression)
    catch
        throw(ShenScopeError(:mcp_schema, "Schema contains an invalid regular expression"))
    end
end

function mcp_pattern_matches(expression::AbstractString, text::AbstractString)
    ncodeunits(text) <= 128 * 1024 || throw(ShenScopeError(:mcp_schema, "Pattern input exceeds validation capacity"))
    try
        occursin(mcp_pattern(expression), text)
    catch error
        error isa ShenScopeError && rethrow()
        throw(ShenScopeError(:mcp_schema, "Schema regular expression exceeded its execution limit"))
    end
end

function mcp_schema_pointer(root, reference::String)
    reference == "#" && return root
    startswith(reference, "#/") || throw(ShenScopeError(:mcp_schema, "Only local JSON Pointer schema references are supported"))
    selected = root
    for encoded in split(reference[3:end], '/')
        occursin(r"~(?![01])", encoded) && throw(ShenScopeError(:mcp_schema, "Invalid schema JSON Pointer escape"))
        key = replace(encoded, "~1" => "/", "~0" => "~")
        if selected isa AbstractDict && haskey(selected, key)
            selected = selected[key]
        elseif selected isa AbstractVector && occursin(r"^(0|[1-9][0-9]*)$", key)
            index = try parse(Int, key) + 1 catch; 0; end
            1 <= index <= length(selected) || throw(ShenScopeError(:mcp_schema, "Schema reference index does not exist"))
            selected = selected[index]
        else
            throw(ShenScopeError(:mcp_schema, "Schema reference does not exist"))
        end
    end
    selected isa AbstractDict || selected isa Bool || throw(ShenScopeError(:mcp_schema, "Schema reference does not name a schema"))
    selected
end

function mcp_schema_strings(value, label::String)
    value isa AbstractVector && length(value) <= 512 && all(item -> item isa AbstractString && isvalid(item), value) ||
        throw(ShenScopeError(:mcp_schema, label * " must be a bounded string array"))
    length(unique(value)) == length(value) || throw(ShenScopeError(:mcp_schema, label * " contains duplicates"))
    value
end

function check_mcp_schema(schema; root = schema, depth = 0, count = Ref(0))
    depth == 0 && mcp_json_value(schema; max_bytes = MCP_MAX_SCHEMA_BYTES)
    count[] += 1
    count[] <= 20000 && depth <= 64 || throw(ShenScopeError(:mcp_schema, "Schema complexity exceeds capacity"))
    schema isa Bool && return schema
    schema isa AbstractDict || throw(ShenScopeError(:mcp_schema, "Schema must be an object or boolean"))
    depth == 0 && ncodeunits(canonical(schema)) > MCP_MAX_SCHEMA_BYTES &&
        throw(ShenScopeError(:mcp_schema, "Schema exceeds byte capacity"))
    for key in keys(schema)
        key isa AbstractString && (key in MCP_SCHEMA_ANNOTATIONS || key in MCP_SCHEMA_ASSERTIONS || startswith(key, "x-")) ||
            throw(ShenScopeError(:mcp_schema, "Unsupported schema keyword: " * cliptext(string(key), 80)))
    end
    if haskey(schema, "type")
        types = schema["type"] isa AbstractString ? [schema["type"]] : schema["type"]
        types isa AbstractVector && !isempty(types) && length(unique(types)) == length(types) &&
            all(type -> type in MCP_SCHEMA_TYPES, types) || throw(ShenScopeError(:mcp_schema, "Invalid schema type"))
    end
    if haskey(schema, "enum")
        enumerated = schema["enum"]
        enumerated isa AbstractVector && 1 <= length(enumerated) <= 512 || throw(ShenScopeError(:mcp_schema, "Invalid enum"))
        length(unique(canonical.(enumerated))) == length(enumerated) || throw(ShenScopeError(:mcp_schema, "Enum values must be unique"))
    end
    haskey(schema, "required") && mcp_schema_strings(schema["required"], "required")
    for key in ("minProperties", "maxProperties", "minItems", "maxItems", "minContains", "maxContains", "minLength", "maxLength")
        haskey(schema, key) || continue
        mcp_integer(schema[key], "schema " * key; maximum = MCP_MAX_MESSAGE_BYTES)
    end
    for (minimum, maximum) in (("minProperties", "maxProperties"), ("minItems", "maxItems"), ("minLength", "maxLength"), ("minContains", "maxContains"))
        get(schema, minimum, 0) <= get(schema, maximum, typemax(Int)) || throw(ShenScopeError(:mcp_schema, "Contradictory schema bounds"))
    end
    for key in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf")
        haskey(schema, key) || continue
        value = schema[key]
        value isa Real && !(value isa Bool) && isfinite(value) || throw(ShenScopeError(:mcp_schema, "Invalid schema numeric bound"))
    end
    haskey(schema, "multipleOf") && schema["multipleOf"] <= 0 && throw(ShenScopeError(:mcp_schema, "multipleOf must be positive"))
    haskey(schema, "uniqueItems") && !(schema["uniqueItems"] isa Bool) && throw(ShenScopeError(:mcp_schema, "uniqueItems must be boolean"))
    haskey(schema, "pattern") && (schema["pattern"] isa AbstractString ? mcp_pattern(schema["pattern"]) : throw(ShenScopeError(:mcp_schema, "Pattern must be a string")))
    recurse = child -> check_mcp_schema(child; root, depth = depth + 1, count)
    for key in ("properties", "patternProperties", "\$defs", "definitions", "dependentSchemas")
        haskey(schema, key) || continue
        map = schema[key]
        map isa AbstractDict || throw(ShenScopeError(:mcp_schema, "Schema map must be an object"))
        for (name, child) in map
            name isa AbstractString || throw(ShenScopeError(:mcp_schema, "Schema property name must be a string"))
            key == "patternProperties" && mcp_pattern(name)
            recurse(child)
        end
    end
    for key in ("additionalProperties", "propertyNames", "additionalItems", "contains", "not", "if", "then", "else")
        haskey(schema, key) && recurse(schema[key])
    end
    for key in ("allOf", "anyOf", "oneOf", "prefixItems")
        haskey(schema, key) || continue
        children = schema[key]
        children isa AbstractVector && length(children) <= 256 && (key == "prefixItems" || !isempty(children)) ||
            throw(ShenScopeError(:mcp_schema, "Invalid schema alternatives"))
        foreach(recurse, children)
    end
    if haskey(schema, "items")
        children = schema["items"]
        if children isa AbstractVector
            length(children) <= 256 || throw(ShenScopeError(:mcp_schema, "Tuple schema exceeds capacity"))
            haskey(schema, "prefixItems") && throw(ShenScopeError(:mcp_schema, "Cannot combine tuple items with prefixItems"))
            foreach(recurse, children)
        else
            recurse(children)
        end
    end
    for key in ("dependentRequired", "dependencies")
        haskey(schema, key) || continue
        map = schema[key]
        map isa AbstractDict || throw(ShenScopeError(:mcp_schema, "Invalid property dependencies"))
        for child in values(map)
            child isa AbstractVector ? mcp_schema_strings(child, key) : key == "dependencies" ? recurse(child) :
                throw(ShenScopeError(:mcp_schema, "dependentRequired entries must be arrays"))
        end
    end
    if haskey(schema, "\$ref")
        reference = schema["\$ref"]
        reference isa AbstractString && ncodeunits(reference) <= 2048 || throw(ShenScopeError(:mcp_schema, "Invalid schema reference"))
        mcp_schema_pointer(root, reference)
    end
    schema
end

function mcp_instance_type(value, type::String)
    type == "object" && return value isa AbstractDict
    type == "array" && return value isa AbstractVector
    type == "string" && return value isa AbstractString
    type == "boolean" && return value isa Bool
    type == "null" && return value === nothing
    type == "number" && return value isa Real && !(value isa Bool) && isfinite(value)
    type == "integer" && return value isa Real && !(value isa Bool) && isfinite(value) && isinteger(value)
    false
end

function mcp_schema_matches(value, schema, root, path::String, depth::Int, count, refs)
    try
        validate_mcp_instance(value, schema, root, path, depth, count, refs)
        true
    catch error
        error isa ShenScopeError && error.code == :mcp_arguments || rethrow()
        false
    end
end

function validate_mcp_instance(value, schema, root, path::String, depth::Int, count, refs)
    count[] += 1
    depth <= 64 && count[] <= 50000 || throw(ShenScopeError(:mcp_schema, "Schema validation exceeds execution capacity"))
    fail(message) = throw(ShenScopeError(:mcp_arguments, path * " " * message))
    schema === true && return value
    schema === false && fail("is rejected by the schema")
    if haskey(schema, "\$ref")
        reference = schema["\$ref"]
        marker = (reference, path)
        marker in refs && throw(ShenScopeError(:mcp_schema, "Schema reference cycle does not advance the instance"))
        push!(refs, marker)
        try
            validate_mcp_instance(value, mcp_schema_pointer(root, reference), root, path, depth + 1, count, refs)
        finally
            delete!(refs, marker)
        end
    end
    descend(child, child_schema, child_path = path) = validate_mcp_instance(child, child_schema, root, child_path, depth + 1, count, refs)
    matches(child_schema) = mcp_schema_matches(value, child_schema, root, path, depth + 1, count, refs)
    if haskey(schema, "type")
        types = schema["type"] isa AbstractString ? [schema["type"]] : schema["type"]
        any(type -> mcp_instance_type(value, type), types) || fail("has the wrong type")
    end
    haskey(schema, "const") && canonical(value) != canonical(schema["const"]) && fail("does not match const")
    haskey(schema, "enum") && !(canonical(value) in canonical.(schema["enum"])) && fail("is outside enum")
    haskey(schema, "allOf") && foreach(child -> descend(value, child), schema["allOf"])
    haskey(schema, "anyOf") && !any(matches, schema["anyOf"]) && fail("does not match any alternative")
    haskey(schema, "oneOf") && Base.count(matches, schema["oneOf"]) != 1 && fail("must match exactly one alternative")
    haskey(schema, "not") && matches(schema["not"]) && fail("matches a forbidden schema")
    if haskey(schema, "if")
        branch = matches(schema["if"]) ? "then" : "else"
        haskey(schema, branch) && descend(value, schema[branch])
    end
    if value isa AbstractDict
        length(value) >= get(schema, "minProperties", 0) && length(value) <= get(schema, "maxProperties", typemax(Int)) || fail("has an invalid property count")
        all(key -> haskey(value, key), get(schema, "required", String[])) || fail("is missing a required property")
        properties = get(schema, "properties", Dict())
        patterns = get(schema, "patternProperties", Dict())
        for (key, child) in value
            haskey(schema, "propertyNames") && descend(key, schema["propertyNames"], path * ".<key>")
            covered = haskey(properties, key)
            covered && descend(child, properties[key], path * "." * cliptext(key, 128))
            for (pattern, child_schema) in patterns
                mcp_pattern_matches(pattern, key) || continue
                covered = true
                descend(child, child_schema, path * "." * cliptext(key, 128))
            end
            covered || descend(child, get(schema, "additionalProperties", true), path * "." * cliptext(key, 128))
        end
        for key in ("dependencies", "dependentRequired", "dependentSchemas")
            for (trigger, dependency) in get(schema, key, Dict())
                haskey(value, trigger) || continue
                if dependency isa AbstractVector
                    all(name -> haskey(value, name), dependency) || fail("is missing a dependent property")
                else
                    descend(value, dependency)
                end
            end
        end
    elseif value isa AbstractVector
        length(value) >= get(schema, "minItems", 0) && length(value) <= get(schema, "maxItems", typemax(Int)) || fail("has an invalid item count")
        get(schema, "uniqueItems", false) && length(unique(canonical.(value))) != length(value) && fail("contains duplicate items")
        items = get(schema, "items", true)
        prefix = get(schema, "prefixItems", items isa AbstractVector ? items : Any[])
        rest = items isa AbstractVector ? get(schema, "additionalItems", true) : items
        for (index, child) in enumerate(value)
            descend(child, index <= length(prefix) ? prefix[index] : rest, path * "[" * string(index) * "]")
        end
        if haskey(schema, "contains")
            matched = sum(child -> mcp_schema_matches(child, schema["contains"], root, path, depth + 1, count, refs), value; init = 0)
            get(schema, "minContains", 1) <= matched <= get(schema, "maxContains", typemax(Int)) || fail("has an invalid matching item count")
        end
    elseif value isa AbstractString
        length(value) >= get(schema, "minLength", 0) && length(value) <= get(schema, "maxLength", typemax(Int)) || fail("has an invalid string length")
        haskey(schema, "pattern") && !mcp_pattern_matches(schema["pattern"], value) && fail("does not match its pattern")
    elseif value isa Real && !(value isa Bool)
        value >= get(schema, "minimum", -Inf) && value <= get(schema, "maximum", Inf) || fail("is outside numeric bounds")
        haskey(schema, "exclusiveMinimum") && value <= schema["exclusiveMinimum"] && fail("is below the exclusive bound")
        haskey(schema, "exclusiveMaximum") && value >= schema["exclusiveMaximum"] && fail("is above the exclusive bound")
        if haskey(schema, "multipleOf")
            factor = value / schema["multipleOf"]
            isfinite(factor) && isapprox(factor, round(factor); atol = 1e-10, rtol = 1e-12) || fail("is not a required multiple")
        end
    end
    value
end

function validate_mcp_schema(value, schema; path = "arguments")
    mcp_json_value(value)
    check_mcp_schema(schema)
    validate_mcp_instance(value, schema, schema, path, 0, Ref(0), Set{Tuple{String,String}}())
end
