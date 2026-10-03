module ShenScope

using Dates, SHA, TOML, UUIDs, JSON3, HTTP
using Base.ScopedValues: ScopedValue, with

const VERSION = v"0.1.0"

include("Core/Types.jl")
include("Runtime/Cancellation.jl")
include("Security/Budgets.jl")
include("Security/Permissions.jl")
include("Runtime/Context.jl")
include("Storage/Journal.jl")
include("Context/Sessions.jl")

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

function main(args = ARGS)
    if isempty(args) || args == ["--help"]
        println("ShenScope — Open coding intelligence for serious codebases.")
        println("Usage: shenscope --version")
        return 0
    elseif args == ["--version"]
        println("ShenScope ", VERSION)
        return 0
    end
    println(stderr, "Unknown command: ", first(args))
    return 2
end

end
