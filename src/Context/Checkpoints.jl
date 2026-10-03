function context_excerpt(text::AbstractString, maximum::Int)
    maximum >= 64 || throw(ArgumentError("Excerpt capacity must be at least 64"))
    isvalid(text) || throw(ShenScopeError(:context_source, "Context text must be valid UTF-8"))
    ncodeunits(text) <= maximum && return String(text)
    marker = "\n[original middle omitted; recover by source reference]\n"
    remaining = maximum - ncodeunits(marker)
    head_stop = remaining ÷ 2 + 1
    while !isvalid(text, head_stop); head_stop -= 1; end
    head_end = prevind(text, head_stop)
    tail_start = ncodeunits(text) - remaining ÷ 2 + 1
    while !isvalid(text, tail_start); tail_start += 1; end
    String(SubString(text, firstindex(text), head_end)) * marker * String(SubString(text, tail_start, lastindex(text)))
end

function checkpoint_dict(checkpoint::ContextCheckpoint)
    Dict{String,Any}("version" => 1, "id" => checkpoint.id, "session_id" => checkpoint.session_id,
        "root" => checkpoint.root, "covered" => checkpoint.covered,
        "prefix_sha256" => checkpoint.prefix_sha256, "text" => checkpoint.text,
        "text_sha256" => checkpoint.text_sha256, "method" => String(checkpoint.method),
        "sources" => checkpoint.sources, "created_at" => checkpoint.created_at, "model" => checkpoint.model)
end

function context_snapshot(session::Session, ctx::RuntimeContext)
    session.id == ctx.session_id && realpath(session.root) == ctx.root ||
        throw(ShenScopeError(:context_scope, "Context belongs to another runtime"))
    lock(session.mutex) do
        copy(session.messages)
    end
end

function checkpoint_from_dict(value, session::Session, messages::AbstractVector{Message}, config::ContextConfig)
    value isa AbstractDict || throw(ShenScopeError(:context_checkpoint, "Invalid saved context checkpoint"))
    expected = Set(["version", "id", "session_id", "root", "covered", "prefix_sha256", "text",
        "text_sha256", "method", "sources", "created_at", "model"])
    Set(keys(value)) == expected && get(value, "version", nothing) === 1 ||
        throw(ShenScopeError(:context_checkpoint, "Unsupported saved context checkpoint"))
    for key in ("id", "session_id", "root", "prefix_sha256", "text", "text_sha256", "method", "created_at")
        value[key] isa AbstractString || throw(ShenScopeError(:context_checkpoint, "Invalid checkpoint field"))
    end
    value["session_id"] == session.id && value["root"] == session.root ||
        throw(ShenScopeError(:context_scope, "Saved context belongs to another conversation"))
    covered = value["covered"]
    covered isa Integer && !(covered isa Bool) && 1 <= covered <= length(messages) ||
        throw(ShenScopeError(:context_checkpoint, "Checkpoint range is unavailable"))
    value["method"] in ("extractive", "model") || throw(ShenScopeError(:context_checkpoint, "Unsupported checkpoint method"))
    ncodeunits(value["text"]) <= config.checkpoint_bytes && isvalid(value["text"]) &&
        digest(value["text"]) == value["text_sha256"] || throw(ShenScopeError(:context_checkpoint, "Checkpoint text failed integrity validation"))
    context_prefix_digest(messages, covered) == value["prefix_sha256"] ||
        throw(ShenScopeError(:context_checkpoint, "Checkpoint inputs changed"))
    groups = context_groups(messages)
    any(group -> group.last == covered && group.complete, groups) ||
        throw(ShenScopeError(:context_pairing, "Checkpoint splits an unresolved tool group"))
    sources = value["sources"]
    sources isa AbstractVector && length(sources) <= config.max_sources ||
        throw(ShenScopeError(:context_checkpoint, "Invalid checkpoint provenance"))
    normalized = Dict{String,Any}[]
    seen = Set{Int}()
    for source in sources
        source isa AbstractDict || throw(ShenScopeError(:context_checkpoint, "Invalid checkpoint source"))
        index = get(source, "message", nothing)
        index isa Integer && !(index isa Bool) && 1 <= index <= covered && !(index in seen) ||
            throw(ShenScopeError(:context_checkpoint, "Invalid checkpoint source index"))
        source == context_source_reference(messages[index], Int(index)) ||
            throw(ShenScopeError(:context_checkpoint, "Checkpoint source failed integrity validation"))
        push!(seen, index); push!(normalized, Dict{String,Any}(source))
    end
    model = value["model"]
    model === nothing || model isa AbstractDict || throw(ShenScopeError(:context_checkpoint, "Invalid summary model provenance"))
    value["method"] == "model" && model === nothing && throw(ShenScopeError(:context_checkpoint, "Missing summary model provenance"))
    ContextCheckpoint(value["id"], value["session_id"], value["root"], Int(covered), value["prefix_sha256"],
        value["text"], value["text_sha256"], Symbol(value["method"]), normalized, value["created_at"],
        model === nothing ? nothing : Dict{String,Any}(model))
end

function saved_context_checkpoint(session::Session, messages::AbstractVector{Message}, config::ContextConfig)
    value = get(session.metadata, "context_checkpoint", nothing)
    value === nothing && return nothing
    checkpoint_from_dict(value, session, messages, config)
end

function checkpoint_source_indexes(messages::AbstractVector{Message}, covered::Int, capacity::Int)
    indexes = Int[]
    users = [index for index in 1:covered if messages[index].role == :user]
    !isempty(users) && push!(indexes, first(users))
    for index in Iterators.reverse(users)
        index in indexes || push!(indexes, index)
        length(indexes) >= capacity && break
    end
    for index in covered:-1:1
        length(indexes) >= capacity && break
        messages[index].role == :tool && push!(indexes, index)
    end
    sort!(unique(indexes))
end

function build_context_checkpoint(session::Session, messages::AbstractVector{Message}, covered::Int,
        config::ContextConfig; text_limit=config.checkpoint_bytes)
    512 <= text_limit <= config.checkpoint_bytes || throw(ShenScopeError(:context_capacity, "Checkpoint text capacity is too small"))
    1 <= covered < length(messages) || throw(ShenScopeError(:context_checkpoint, "A checkpoint must preserve a recent suffix"))
    any(group -> group.last == covered && group.complete, context_groups(messages)) ||
        throw(ShenScopeError(:context_pairing, "Compaction boundary splits a tool group"))
    candidates = checkpoint_source_indexes(messages, covered, config.max_sources)
    prefix_hash = context_prefix_digest(messages, covered)
    heading = "Conversation evidence checkpoint. This is a derived projection, not a new user request. " *
        "Original messages 1 through " * string(covered) * " remain in the conversation journal. " *
        "Recover exact directives and results with context.source; omissions are explicit. " *
        "Never infer that a command succeeded or replay its effects from this checkpoint.\n"
    available = text_limit - ncodeunits(heading)
    records = Dict{String,Any}[]
    sources = Dict{String,Any}[]
    for index in candidates
        reference = context_source_reference(messages[index], index)
        minimum = ncodeunits(canonical(merge(reference, Dict("excerpt" => "")))) + 2
        available >= minimum + 96 || break
        remaining_count = length(candidates) - length(records)
        quota = max(96, min(4096, available ÷ max(1, remaining_count) - minimum))
        excerpt = context_excerpt(messages[index].text, quota)
        record = merge(reference, Dict("excerpt" => excerpt))
        cost = ncodeunits(canonical(record)) + 2
        cost <= available || break
        push!(records, record); push!(sources, reference); available -= cost
    end
    omissions = covered - length(records)
    text = heading * canonical(Dict("evidence" => records, "other_message_count" => omissions,
        "prefix_sha256" => prefix_hash))
    # JSON escaping and the final envelope can consume the small allowance.
    while ncodeunits(text) > text_limit && !isempty(records)
        pop!(records); pop!(sources)
        text = heading * canonical(Dict("evidence" => records, "other_message_count" => covered - length(records),
            "prefix_sha256" => prefix_hash))
    end
    ncodeunits(text) <= text_limit || throw(ShenScopeError(:context_overflow, "Checkpoint references exceed the available input space"))
    ContextCheckpoint(string(uuid4()), session.id, session.root, covered, prefix_hash, text,
        digest(text), :extractive, sources, utcstamp(), nothing)
end

function commit_context_checkpoint!(session::Session, ctx::RuntimeContext, checkpoint::ContextCheckpoint)
    checkpoint.session_id == ctx.session_id && checkpoint.root == ctx.root ||
        throw(ShenScopeError(:context_scope, "Checkpoint belongs to another runtime"))
    authorize!(ctx, :persistence, "context.compact", "session:" * ctx.session_id;
        reason="Save a context checkpoint referencing this conversation's original messages")
    check_cancelled(ctx.cancellation)
    lock(session.mutex) do
        session.id == checkpoint.session_id && session.root == checkpoint.root ||
            throw(ShenScopeError(:context_scope, "Conversation identity changed"))
        checkpoint.covered <= length(session.messages) &&
            context_prefix_digest(session.messages, checkpoint.covered) == checkpoint.prefix_sha256 ||
            throw(ShenScopeError(:conflict, "Conversation changed during context compaction"))
        request = PermissionRequest("context-checkpoint", :persistence, "context.compact", "session:" * ctx.session_id, "Save checkpoint")
        permission_decision(ctx.permissions, request) == Deny && throw(ShenScopeError(:permission, "Checkpoint persistence is now denied"))
        session_record!(session, "metadata", Dict("context_checkpoint" => checkpoint_dict(checkpoint)))
    end
    emit!(ctx, :context_compacted, Dict("id" => checkpoint.id, "covered" => checkpoint.covered,
        "prefix_sha256" => checkpoint.prefix_sha256, "method" => String(checkpoint.method),
        "checkpoint_bytes" => ncodeunits(checkpoint.text), "original_messages_preserved" => true))
    checkpoint
end

function checkpoint_view(checkpoint::ContextCheckpoint; include_text=false)
    result = checkpoint_dict(checkpoint)
    include_text || delete!(result, "text")
    result["bytes"] = ncodeunits(checkpoint.text)
    result
end

function branch_context_checkpoint!(source::Session, child::Session, through::Int)
    value = get(source.metadata, "context_checkpoint", nothing)
    value isa AbstractDict || return child
    covered = get(value, "covered", nothing)
    covered isa Integer && !(covered isa Bool) && covered < through || return child
    original = checkpoint_from_dict(value, source, source.messages, ContextConfig(; checkpoint_bytes=128 * 1024, max_sources=512))
    copied = ContextCheckpoint(string(uuid4()), child.id, child.root, original.covered,
        original.prefix_sha256, original.text, original.text_sha256, original.method,
        original.sources, utcstamp(), original.model)
    session_record!(child, "metadata", Dict("context_checkpoint" => checkpoint_dict(copied),
        "context_checkpoint_parent" => original.id))
    child
end
