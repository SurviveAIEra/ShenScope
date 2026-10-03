function skill_yaml_guard(header::String)
    stream = YAML.EventStream(YAML.TokenStream(IOBuffer(header)))
    depth = 0
    nodes = 0
    documents = 0
    while true
        event = YAML.forward!(stream)
        event === nothing && break
        nodes += 1
        nodes <= 4096 || throw(ShenScopeError(:skill_metadata, "Skills metadata exceeds the node limit"))
        event isa YAML.AliasEvent && throw(ShenScopeError(:skill_metadata, "YAML aliases are not supported in Skills metadata"))
        if event isa Union{YAML.ScalarEvent,YAML.MappingStartEvent,YAML.SequenceStartEvent}
            event.anchor === nothing && event.tag === nothing || throw(ShenScopeError(:skill_metadata, "Explicit YAML tags and anchors are not supported in Skills metadata"))
        end
        if event isa Union{YAML.MappingStartEvent,YAML.SequenceStartEvent}
            depth += 1
            depth <= 16 || throw(ShenScopeError(:skill_metadata, "Skills metadata nesting exceeds the limit"))
        elseif event isa Union{YAML.MappingEndEvent,YAML.SequenceEndEvent}
            depth -= 1
        elseif event isa YAML.DocumentStartEvent
            documents += 1
            documents <= 1 || throw(ShenScopeError(:skill_metadata, "Skills frontmatter requires one YAML document"))
        end
        event isa YAML.StreamEndEvent && break
    end
end

function skill_yaml_value(node::YAML.Node)
    if node isa YAML.MappingNode
        result = Dict{String,Any}()
        for (key, value) in node.value
            key isa YAML.ScalarNode && key.tag == "tag:yaml.org,2002:str" || throw(ShenScopeError(:skill_metadata, "Skills metadata keys must be strings"))
            haskey(result, key.value) && throw(ShenScopeError(:skill_metadata, "Duplicate Skills metadata field"))
            result[key.value] = skill_yaml_value(value)
        end
        return result
    elseif node isa YAML.SequenceNode
        return Any[skill_yaml_value(value) for value in node.value]
    elseif node isa YAML.ScalarNode
        node.tag == "tag:yaml.org,2002:timestamp" && return node.value
        node.tag in ("tag:yaml.org,2002:str", "tag:yaml.org,2002:bool", "tag:yaml.org,2002:int", "tag:yaml.org,2002:float", "tag:yaml.org,2002:null") ||
            throw(ShenScopeError(:skill_metadata, "Unsupported Skills metadata scalar"))
        value = YAML.construct_object(YAML.SafeConstructor(), node)
        value isa AbstractFloat && !isfinite(value) && throw(ShenScopeError(:skill_metadata, "Skills metadata numbers must be finite"))
        return value
    end
    throw(ShenScopeError(:skill_metadata, "Unsupported Skills metadata node"))
end

function skill_frontmatter(raw::String)
    isvalid(raw) || throw(ShenScopeError(:skill_encoding, "SKILL.md must contain valid UTF-8"))
    text = startswith(raw, '\ufeff') ? chop(raw; head = 1, tail = 0) : raw
    lines = split(replace(text, "\r\n" => "\n", "\r" => "\n"), '\n'; keepempty = true)
    !isempty(lines) && lines[1] == "---" || throw(ShenScopeError(:skill_frontmatter, "SKILL.md requires YAML frontmatter"))
    boundary = nothing
    bytes = 0
    for index in 2:length(lines)
        if lines[index] in ("---", "...")
            boundary = index
            break
        end
        bytes += ncodeunits(lines[index]) + 1
        bytes <= 16 * 1024 || throw(ShenScopeError(:skill_metadata, "Skills frontmatter exceeds 16 KiB"))
    end
    boundary !== nothing || throw(ShenScopeError(:skill_frontmatter, "SKILL.md frontmatter delimiter is missing"))
    header = join(lines[2:boundary-1], "\n")
    metadata = try
        skill_yaml_guard(header)
        node = YAML.compose(YAML.EventStream(YAML.TokenStream(IOBuffer(header))), YAML.Resolver())
        node isa YAML.MappingNode || throw(ShenScopeError(:skill_metadata, "Skills frontmatter must be a mapping"))
        skill_yaml_value(node)
    catch error
        error isa ShenScopeError && rethrow()
        throw(ShenScopeError(:skill_metadata, "SKILL.md contains invalid YAML metadata"))
    end
    metadata, join(lines[boundary+1:end], "\n")
end

function skill_allowed_tools(value)
    value === nothing && return nothing
    names = value isa AbstractString ? split(strip(value), r"[ ,]+"; keepempty = false) : value
    names isa AbstractVector && length(names) <= 128 || throw(ShenScopeError(:skill_metadata, "allowed-tools requires a bounded list of tool names"))
    aliases = Dict("Read" => "read", "Write" => "write", "Edit" => "edit", "Bash" => "process", "Grep" => "search", "Glob" => "search")
    result = String[]
    for name in names
        name isa AbstractString && 1 <= ncodeunits(name) <= 128 && occursin(r"^[A-Za-z0-9_.-]+$", name) ||
            throw(ShenScopeError(:skill_metadata, "allowed-tools supports exact tool names; permission patterns require explicit Core configuration"))
        push!(result, get(aliases, name, String(name)))
    end
    unique(result)
end

function skill_manifest(raw::String, path::String, scope::Symbol)
    metadata, _ = skill_frontmatter(raw)
    name = skill_name(get(metadata, "name", nothing))
    description = get(metadata, "description", nothing)
    description isa AbstractString && !isempty(strip(description)) && length(description) <= 1024 ||
        throw(ShenScopeError(:skill_description, "Skills require a nonempty description of at most 1024 characters"))
    boolean = function (field, default)
        value = get(metadata, field, default)
        value isa Bool || throw(ShenScopeError(:skill_metadata, "Skills invocation flags must be boolean"))
        value
    end
    allowed = skill_allowed_tools(get(metadata, "allowed-tools", nothing))
    SkillManifest("skill-" * digest(scope == :project ? "project:" * path : "user:" * path)[1:24], name, String(description), scope,
        path, dirname(path), digest(raw), metadata, boolean("disable-model-invocation", false), boolean("user-invocable", true), allowed)
end
