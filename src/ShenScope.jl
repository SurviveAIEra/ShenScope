module ShenScope

using Dates, SHA, TOML, UUIDs, JSON3, HTTP, REPL, YAML, FileWatching
using Base.ScopedValues: ScopedValue, with

const VERSION = v"0.1.0"

include("Core/Types.jl")
include("Runtime/Cancellation.jl")
include("Runtime/UTF8.jl")
include("Security/Budgets.jl")
include("Security/Permissions.jl")
include("Runtime/Context.jl")
include("Runtime/OwnedOperations.jl")
include("Security/ComputeLimits.jl")
include("Security/ComputeSeccomp.jl")
include("Security/Files.jl")
include("Storage/Journal.jl")
include("Storage/JSON.jl")
include("Storage/BoundedJSON.jl")
include("Security/ComputeProtocol.jl")
include("Storage/AtomicStreams.jl")
include("Storage/Staging.jl")
include("Storage/JournalStream.jl")
include("Storage/Versioned.jl")
include("Context/Sessions.jl")
include("Models/RetryTypes.jl")
include("Models/RetryHeaders.jl")
include("Models/RetryDecisions.jl")
include("Models/CircuitTypes.jl")
include("Models/Provider.jl")
include("Models/CircuitState.jl")
include("Models/Requests.jl")
include("Models/Errors.jl")
include("Models/Delivery.jl")
include("Models/Streaming.jl")
include("Models/RetryRuntime.jl")
include("Models/HTTP.jl")
include("Models/CatalogTypes.jl")
include("Models/ServiceRequests.jl")
include("Models/ServiceTransport.jl")
include("Models/CatalogParsing.jl")
include("Models/CatalogCache.jl")
include("Models/CircuitServices.jl")
include("Models/TokenCounts.jl")
include("Models/RoutingTypes.jl")
include("Models/RoutingConfig.jl")
include("Models/RoutingCapabilities.jl")
include("Models/RoutingPlans.jl")
include("Models/RoutingState.jl")
include("Models/RoutingRuntime.jl")
include("Tools/Schema.jl")
include("Tools/Models.jl")
include("Tools/Files.jl")
include("Tools/Processes.jl")
include("Memory/Store.jl")
include("ProjectData/Types.jl")
include("ProjectData/Locations.jl")
include("ProjectData/JSONC.jl")
include("ProjectData/State.jl")
include("ProjectData/Inputs.jl")
include("ProjectData/Backends.jl")
include("ProjectData/CompilerConfig.jl")
include("ProjectData/TypeScript.jl")
include("ProjectData/Queries.jl")
include("ProjectData/Navigation.jl")
include("ProjectData/Fingerprints.jl")
include("ProjectData/Replay.jl")
include("ProjectData/Compaction.jl")
include("ProjectData/WatchTypes.jl")
include("ProjectData/WatchSnapshots.jl")
include("ProjectData/WatchBatches.jl")
include("ProjectData/WatchRuntime.jl")
include("Git/HistoryTypes.jl")
include("Git/HistoryRepository.jl")
include("Git/HistoryProcess.jl")
include("Git/HistoryParsing.jl")
include("Git/HistorySnapshot.jl")
include("Analysis/Builtin.jl")
include("Analysis/HistoryEvidence.jl")
include("Analysis/Cochange.jl")
include("Analysis/Risk.jl")
include("Analysis/IsolatedWorker.jl")
include("Runtime/ComputeProcess.jl")
include("Analysis/Definitions.jl")
include("Analysis/Registry.jl")
include("Analysis/ExternalTests.jl")
include("Analysis/ArchiveTypes.jl")
include("Analysis/ArchiveManifests.jl")
include("Analysis/ArchivePointers.jl")
include("Analysis/ArchiveLifecycle.jl")
include("Analysis/GraphSnapshots.jl")
include("Analysis/GraphEvidence.jl")
include("Analysis/GraphRuntime.jl")
include("Tools/Project.jl")
include("Tools/Analyzers.jl")
include("Analysis/Jobs.jl")
include("Extensions/Contracts.jl")
include("Extensions/CompilerDiagnostics.jl")
include("Tools/Diagnostics.jl")
include("MCP/Types.jl")
include("MCP/Schema.jl")
include("MCP/JSONRPC.jl")
include("MCP/Stdio.jl")
include("MCP/SSE.jl")
include("MCP/HTTP.jl")
include("MCP/Client.jl")
include("MCP/Discovery.jl")
include("MCP/Content.jl")
include("MCP/Manager.jl")
include("Tools/MCP.jl")
include("Skills/Types.jl")
include("Skills/Metadata.jl")
include("Skills/Discovery.jl")
include("Skills/Activation.jl")
include("Skills/Projection.jl")
include("Tools/Skills.jl")
include("Hooks/Types.jl")
include("Hooks/Config.jl")
include("Hooks/Catalog.jl")
include("Hooks/Runner.jl")
include("Tools/Hooks.jl")
include("Hooks/Lifecycle.jl")
include("Context/Types.jl")
include("Context/Config.jl")
include("Context/Instructions.jl")
include("Context/Accounting.jl")
include("Context/Groups.jl")
include("Context/Checkpoints.jl")
include("Context/Pruning.jl")
include("Context/Projection.jl")
include("Context/Evidence.jl")
include("Context/Summarization.jl")
include("Tools/Context.jl")
include("Tasks/Types.jl")
include("Tasks/Graph.jl")
include("Tasks/Serialization.jl")
include("Tasks/Store.jl")
include("Tasks/Results.jl")
include("Tasks/Lifecycle.jl")
include("Tasks/Queries.jl")
include("Runtime/ToolScheduler.jl")
include("Context/Preparation.jl")
include("Context/Recovery.jl")
include("Core/AgentLoop.jl")
include("Core/Config.jl")
include("Tasks/Executor.jl")
include("Tasks/Runner.jl")
include("Tools/Tasks.jl")
include("Protocol/Framing.jl")
include("Protocol/Server.jl")
include("Protocol/Project.jl")
include("Protocol/ProjectWatch.jl")
include("Protocol/Tasks.jl")
include("Protocol/MCP.jl")
include("Protocol/Skills.jl")
include("Protocol/Hooks.jl")
include("Protocol/Context.jl")
include("Protocol/Analyzers.jl")
include("Protocol/Models.jl")

export PROTOCOL_VERSION, RPCFault, CoreServer, read_rpc, write_rpc, handle_rpc,
    dispatch_rpc, serve_stdio, stop_server!, capability_manifest

export core_tools, execute_batch, AgentControl, steer!, run_agent!, load_config,
    save_config!, provider_from_config, limits_from_config, permissions_from_config
export VersionedStore, version_get, version_put!, version_list, version_history,
    MemoryStore, memory_store, memory_put!, memory_get, memory_search, memory_delete!,
    memory_export, memory_import!, lexical_tokens, MemoryTool
export SymbolId, SourceRange, SourceMap, CodeSymbol, Relation, FileFacts, CallReference, SymbolOccurrence,
    BackendCapabilities, ProjectState, ProjectDelta, TreeSitterBackend, CodeGraphBackend,
    GoASTBackend, TypeScriptSemanticBackend, backend_capabilities, backend_close!, build!, update!, load_project,
    graph_snapshot, graph_search, graph_traverse, ProjectTool, ImpactAnalyzer,
    TestSelectionAnalyzer, ArchitectureAnalyzer, analyze, analyzer_name, requirements
export compact_project!, project_fingerprint
export GitHistoryLimits, GitHistoryChange, GitHistoryCommit, GitHistorySnapshot,
    git_history_snapshot, git_history_coverage, GitCochangeAnalyzer, RiskAnalyzer
export ComputeLimits, AnalyzerTestCase, AnalyzerDefinition, AnalyzerManager, AnalyzersTool,
    register_analyzer!, analyzer_list, analyzer_inspect, select_analyzer!, remove_analyzer!,
    validate_analyzer!, evaluate_analyzer!, cancel_analyzer!, cleanup_analyzers!, run_isolated_compute
export IsolatedJuliaAnalyzer, AnalyzerArchive, analyzer_archive, archive_analyzer!,
    analyzer_archive_list, analyzer_archive_inspect, restore_analyzer!, promote_analyzer!,
    rollback_analyzer!, analyzer_archive_history
export ModelDescriptor, ModelCatalogManager, ModelsTool, model_descriptor_dict,
    model_catalog_view, refresh_model_catalog!, count_model_tokens, model_request_from_dict,
    OperationManager, start_operation!, owned_operation, close_operations!, bounded_canonical_json
export ModelRetryPolicy, ModelRetryAdvice, ModelAttemptFailure, ModelRetryDecision,
    ModelCircuitPolicy, ModelCircuitManager, ModelProviderRuntime, model_retry_decision,
    model_health_snapshot, reset_model_health!, cleanup_models_tool!, bind_models_provider!
export ModelSelection, ModelProfile, ModelRoleRoute, ModelFleet, RoutedProvider,
    model_routing_from_config, model_route_plan, model_route_plan_dict, model_fleet_metadata,
    model_price_bound, close_model_fleet!, agent_model_provider
export ProjectWatchOptions, ProjectWatch, start_project_watch, stop_project_watch!,
    project_watch_status, refresh_project_watch!

export ProviderConfig, HTTPProvider, MockProvider, provider_name, capabilities,
    response, prepare_request, stream_chat, estimate_request_tokens, SSEDecoder,
    feed_sse!, finish_sse!, declaration, tool_name, tool_schema, execution_mode,
    validate_schema, execute, execute_call, ReadTool, SearchTool, EditTool, WriteTool,
    PatchTool, ProcessTool, ProcessManager, cleanup_processes!, GitTool
export contract_report, interface_catalog, dispatch_ambiguities, invoke_extension_latest,
    compiler_report, run_compiler_diagnostic, compiler_targets, DiagnosticsTool
export WorkStatus, WorkSpec, WorkRetryPolicy, WorkLease, WorkFailure, WorkReceipt,
    WorkRecord, Workflow, create_workflow, load_workflow, claim_work!, start_work!,
    heartbeat_work!, finish_work!, cancel_work!, recover_workflow!, reconcile_work!, work_view,
    workflow_status, workflow_tasks, workflow_task, list_workflows, materialize_work_result,
    WorkExecutor, execute_work, run_workflow!, TaskTool

export MCPServerSpec, MCPClient, MCPManager, MCPRemoteError, MCPControlTool, MCPRemoteTool,
    mcp_connect!, mcp_disconnect!, mcp_reconnect!, mcp_request!, mcp_status, mcp_test_connection!, mcp_catalog,
    mcp_call_tool!, mcp_read_resource!, mcp_get_prompt!, mcp_subscribe!, mcp_complete!,
    mcp_servers, mcp_client!, cleanup_mcp!, mcp_tool_alias, validate_mcp_schema

export SkillConfig, SkillManifest, SkillCatalog, SkillActivation, SkillManager, SkillsTool,
    skill_config, skills_list, discover_skills, activate_skill!, deactivate_skill!,
    skill_read_source, skill_read_resource, bind_skills_session!, restore_skills!, cleanup_skills!

export HookPoint, HookSpec, HookConfig, HookCatalog, HookOutcome, HookManager, HooksTool,
    hook_config, hook_point, hooks_list, hooks_read_configuration, run_hook!, cleanup_hooks!,
    with_lifecycle_hooks, run_lifecycle_hooks!

export ContextConfig, InstructionSource, ContextGroup, ContextMeasure, ContextCheckpoint,
    ContextProjection, ContextManager, ContextTool, context_config, context_groups,
    load_project_instructions, context_measure, measure_view, prepare_context!,
    context_status, context_source, context_artifact, context_compact!, cleanup_context!

export AbstractModelProvider, AbstractTool, AbstractSandbox, AbstractProjectDataBackend,
    AbstractAnalyzer, AbstractContextStrategy, AbstractScheduler, ShenScopeError,
    ToolCall, ToolResult, Message, ModelCapabilities, Usage, ModelResponse, ModelRequest,
    AgentEvent, CancellationToken, cancel!, iscancelled, check_cancelled,
    BudgetLimits, BudgetLedger, reserve!, settle!, release!, budget_status,
    PermissionDecision, Allow, Ask, Deny, PermissionPolicy, PermissionRequest,
    RuntimeContext, child_context, with_context, current_context, emit!, authorize!,
    workspace_path, Journal, journal_records, append_record!, atomic_write,
    Session, new_session, load_session, add_message!, set_status!, record_usage!,
    rename_session!, list_sessions, branch_session, recover_tool_pairs!,
    parsejson, canonical, digest, cliptext

include("CLI/Main.jl")
include("CLI/Project.jl")
include("CLI/ProjectWatch.jl")
include("CLI/MCP.jl")
include("CLI/Skills.jl")
include("CLI/Hooks.jl")
include("CLI/Context.jl")
include("CLI/Analyzers.jl")
include("CLI/Models.jl")
include("CLI/TUI.jl")
main(args=ARGS)=cli_main(args)

end
