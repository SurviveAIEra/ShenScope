module ShenScope

using Dates, SHA, TOML, UUIDs, JSON3, HTTP, REPL
using Base.ScopedValues: ScopedValue, with

const VERSION = v"0.1.0"

include("Core/Types.jl")
include("Runtime/Cancellation.jl")
include("Security/Budgets.jl")
include("Security/Permissions.jl")
include("Runtime/Context.jl")
include("Storage/Journal.jl")
include("Context/Sessions.jl")
include("Models/Provider.jl")
include("Models/Requests.jl")
include("Models/Streaming.jl")
include("Models/HTTP.jl")
include("Tools/Schema.jl")
include("Tools/Files.jl")
include("Tools/Processes.jl")
include("Runtime/ToolScheduler.jl")
include("Context/Preparation.jl")
include("Core/AgentLoop.jl")
include("Core/Config.jl")
include("Protocol/Framing.jl")
include("Protocol/Server.jl")

export PROTOCOL_VERSION, RPCFault, CoreServer, read_rpc, write_rpc, handle_rpc,
    dispatch_rpc, serve_stdio, stop_server!, capability_manifest

export core_tools, execute_batch, AgentControl, steer!, run_agent!, load_config,
    save_config!, provider_from_config, limits_from_config, permissions_from_config

export ProviderConfig, HTTPProvider, MockProvider, provider_name, capabilities,
    response, prepare_request, stream_chat, estimate_request_tokens, SSEDecoder,
    feed_sse!, finish_sse!, declaration, tool_name, tool_schema, execution_mode,
    validate_schema, execute, execute_call, ReadTool, SearchTool, EditTool, WriteTool,
    PatchTool, ProcessTool, ProcessManager, cleanup_processes!, GitTool

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
include("CLI/TUI.jl")
main(args=ARGS)=cli_main(args)

end
