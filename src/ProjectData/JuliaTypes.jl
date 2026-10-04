const JULIA_SYNTAX_MAX_NODES = 200_000
const JULIA_SYNTAX_MAX_DEPTH = 256
const JULIA_SYNTAX_MAX_SYMBOLS = 20_000
const JULIA_SYNTAX_MAX_CALLS = 50_000
const JULIA_SYNTAX_MAX_TEXT = 16_384
const JULIA_SYNTAX_MAX_SOURCE = 2 * 1024 * 1024
const JULIA_SYNTAX_MAX_PARSE_NESTING = 128
const JULIA_PROJECT_ACTIONS = Set(["julia_methods", "julia_dispatch", "julia_structure"])

struct JuliaSyntaxBackend <: AbstractProjectDataBackend end
backend_capabilities(::JuliaSyntaxBackend) = BackendCapabilities(; name="julia_syntax",
    languages=["julia"], calls=:heuristic, diagnostics=true, inheritance=true)

struct JuliaSyntaxScope
    owner::SymbolId
    qualification::String
    module_name::String
    context_kind::Symbol
end

mutable struct JuliaSyntaxExtraction
    source::SourceMap
    context::RuntimeContext
    symbols::Vector{CodeSymbol}
    relations::Vector{Relation}
    references::Vector{CallReference}
    diagnostics::Vector{Dict{String,Any}}
    calls::Vector{Dict{String,Any}}
    imports::Vector{Dict{String,Any}}
    includes::Vector{Dict{String,Any}}
    exports::Vector{Dict{String,Any}}
    supertypes::Vector{Tuple{SymbolId,String,SourceRange}}
    ordinals::Dict{String,Int}
    declaration_ids::Set{SymbolId}
    visited::Int
end

function JuliaSyntaxExtraction(source::SourceMap, context::RuntimeContext)
    JuliaSyntaxExtraction(source, context, CodeSymbol[], Relation[], CallReference[],
        Dict{String,Any}[], Dict{String,Any}[], Dict{String,Any}[], Dict{String,Any}[],
        Dict{String,Any}[], Tuple{SymbolId,String,SourceRange}[], Dict{String,Int}(), Set{SymbolId}(), 0)
end

function julia_syntax_checkpoint!(extraction::JuliaSyntaxExtraction, depth::Int)
    extraction.visited += 1
    extraction.visited <= JULIA_SYNTAX_MAX_NODES && depth <= JULIA_SYNTAX_MAX_DEPTH ||
        throw(ShenScopeError(:graph, "Julia syntax extraction exceeds its node or depth limit"))
    extraction.visited % 256 == 0 || return
    check_cancelled(extraction.context.cancellation)
    lock(extraction.context.budget.mutex) do
        check_budget(extraction.context.budget)
    end
    request = PermissionRequest("julia-extract", :read, "project.index", extraction.context.root, "Parse Julia source")
    permission_decision(extraction.context.permissions, request) != Deny ||
        throw(ShenScopeError(:permission, "Julia source reads were revoked"))
    yield()
end

julia_node_kind(node) = string(JuliaSyntax.kind(node))
julia_node_children(node) = JuliaSyntax.children(node)

function julia_syntax_text(node; maximum=JULIA_SYNTAX_MAX_TEXT)
    JuliaSyntax.span(node) <= maximum || throw(ShenScopeError(:graph, "Julia syntax text exceeds capacity"))
    String(JuliaSyntax.sourcetext(node))
end

function julia_syntax_identity(node)
    # Tokens preserve identifiers and literals; trivia never contributes to identity.
    children = julia_node_children(node)
    isempty(children) && return [julia_node_kind(node), julia_syntax_text(node)]
    Any[julia_node_kind(node), (julia_syntax_identity(child) for child in children)...]
end

julia_qualified_name(scope::JuliaSyntaxScope, name::String) =
    isempty(scope.qualification) ? name : scope.qualification * "." * name
