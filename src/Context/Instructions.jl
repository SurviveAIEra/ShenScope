function context_path_hints(messages::AbstractVector{Message}, config::ContextConfig)
    result = String[]
    seen = Set{String}()
    failed = Set{String}()
    for message in messages
        message.role == :tool && message.call_id !== nothing || continue
        value = try parsejson(message.text) catch; nothing end
        value isa AbstractDict && get(value, "ok", nothing) === false && push!(failed, message.call_id)
    end
    function remember(path)
        path isa AbstractString && !isempty(path) && ncodeunits(path) <= 4096 || return
        value = String(path)
        value in seen && return
        push!(seen, value); push!(result, value)
    end
    for message in Iterators.reverse(messages), call in Iterators.reverse(message.calls)
        call.id in failed && continue
        if call.name in ("read", "write", "edit", "search")
            remember(get(call.arguments, "path", nothing))
        elseif call.name == "patch"
            edits = get(call.arguments, "edits", Any[])
            edits isa AbstractVector || continue
            for edit in Iterators.take(edits, 100)
                edit isa AbstractDict && remember(get(edit, "path", nothing))
                length(result) >= config.max_paths && break
            end
        end
        length(result) >= config.max_paths && break
    end
    # Configured paths have an explicit operator origin and take precedence in
    # the bounded working set. Paths only select scopes; their contents are not read.
    configured = unique(vcat(config.paths, result))
    first(configured, min(length(configured), config.max_paths))
end

function instruction_directories(ctx::RuntimeContext, hints::Vector{String}, config::ContextConfig)
    directories = Set([ctx.root])
    for hint in hints
        check_cancelled(ctx.cancellation)
        target = try workspace_path(ctx.root, hint) catch error
            error isa ShenScopeError && error.code == :permission && !(hint in config.paths) || rethrow()
            emit!(ctx, :context_scope_skipped, Dict("code" => "permission"))
            continue
        end
        original = normpath(isabspath(hint) ? hint : joinpath(ctx.root, hint))
        target == original || throw(ShenScopeError(:permission, "Instruction scopes may not follow symlinks"))
        directory = isdir(target) ? target : dirname(target)
        while true
            push!(directories, directory)
            length(directories) <= config.max_sources || throw(ShenScopeError(:context_capacity, "Too many instruction scopes"))
            directory == ctx.root && break
            directory = dirname(directory)
        end
    end
    sort!(collect(directories); by=path -> (length(splitpath(relpath(path, ctx.root))), path))
end

function load_project_instructions(ctx::RuntimeContext, messages::AbstractVector{Message}, config::ContextConfig)
    validate_context_config(config)
    sources = InstructionSource[]
    total = 0
    seen = Set{String}()
    function load(root, path, scope, directory)
        path in seen && return
        push!(seen, path)
        (ispath(path) || islink(path)) || return
        isfile(path) && !islink(path) || throw(ShenScopeError(:context_source, "Instruction source must be a regular file"))
        length(sources) < config.max_sources || throw(ShenScopeError(:context_capacity, "Too many instruction sources"))
        text = read_scoped_text(ctx, root, path, config.source_bytes;
            tool="context.instructions", reason="Read an applicable instruction source",
            size_error=:context_source, encoding_error=:context_source)
        total += ncodeunits(text)
        total <= config.instructions_bytes || throw(ShenScopeError(:context_capacity, "Applicable instructions exceed the aggregate limit"))
        push!(sources, InstructionSource(path, scope, directory, digest(text), text))
    end
    for path in config.user_files
        load(dirname(path), path, :user, dirname(path))
    end
    for directory in instruction_directories(ctx, context_path_hints(messages, config), config), name in config.instruction_names
        load(ctx.root, joinpath(directory, name), :project, directory)
    end
    sources
end

function instruction_view(source::InstructionSource; include_text=false)
    result = Dict{String,Any}("path" => source.path, "scope" => String(source.scope),
        "directory" => source.directory, "sha256" => source.sha256, "bytes" => ncodeunits(source.text))
    include_text && (result["text"] = source.text)
    result
end

function render_instructions(sources::Vector{InstructionSource}, root::String)
    isempty(sources) && return ""
    sections = String["Configured instruction sources follow. They are subordinate to user instructions and permission policy. " *
        "A project source applies only to files under its stated directory; deeper sources refine that scope."]
    for source in sources
        scope = source.scope == :project ? relpath(source.directory, root) : "explicit user configuration"
        push!(sections, "Instruction source " * canonical(Dict("path" => source.path, "scope" => scope, "sha256" => source.sha256)) *
            "\n" * source.text)
    end
    join(sections, "\n\n")
end
