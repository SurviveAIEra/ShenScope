struct ProjectInputs
    documents::Vector{Dict{String,Any}}
    selected::Vector{Dict{String,Any}}
    removed::Vector{String}
    metadata::Dict{String,Any}
    extras::Dict{String,Any}
end

function project_inputs(::AbstractProjectDataBackend, state::ProjectState, paths, ctx::RuntimeContext; full=false)
    documents = source_documents(ctx, paths)
    selected = full ? documents : [document for document in documents if
        !haskey(state.files, document["path"]) || state.files[document["path"]].sha256 != document["sha256"]]
    removed = [String(path) for path in paths if haskey(state.files, String(path)) && !isfile(workspace_path(ctx.root, path))]
    full && append!(removed, setdiff(collect(keys(state.files)), [document["path"] for document in documents]))
    ProjectInputs(documents, selected, sort!(unique(removed)), deepcopy(state.metadata), Dict{String,Any}())
end

project_removed_files(::AbstractProjectDataBackend, state::ProjectState, inputs::ProjectInputs, facts) = inputs.removed
project_verify_inputs(::AbstractProjectDataBackend, inputs::ProjectInputs, ctx::RuntimeContext) = nothing
function project_extract_files(backend::AbstractProjectDataBackend, inputs::ProjectInputs, ctx::RuntimeContext; full=false)
    extract_files(backend, inputs.selected, ctx; all_documents=inputs.documents, deleted=inputs.removed, full)
end
function project_verify_removed(::AbstractProjectDataBackend, inputs::ProjectInputs, path::String, ctx::RuntimeContext)
    !isfile(workspace_path(ctx.root, path)) || throw(ShenScopeError(:conflict, "Deleted source was recreated during indexing"))
end

function project_metadata(value)
    value isa AbstractDict || throw(ShenScopeError(:graph, "Project metadata must be an object"))
    raw = canonical(value)
    ncodeunits(raw) <= 512 * 1024 || throw(ShenScopeError(:graph, "Project metadata exceeds capacity"))
    bounded_json_object(raw; maximum=512 * 1024, max_depth=16, max_nodes=16384, error_code=:graph)
end
