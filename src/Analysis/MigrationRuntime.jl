function analyze(::MigrationAnalyzer, state::ProjectState, request::AbstractDict, ctx::RuntimeContext)
    options = migration_options(request)
    graph = migration_graph(state, request, options, ctx)
    plan = migration_plan(graph, options, ctx)
    result = migration_plan_view(plan, ctx)
    analyzer_graph_current!(graph.snapshot, state, ctx)
    result
end
