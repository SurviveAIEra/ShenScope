# Reference priorities and verified synthesis

This is a partial source review and implementation record. Cloning a repository,
reading a README, or listing a capability is not evidence of full synthesis.
The project remains far below the requested Core size and functional scope.
All agent behavior is independently authored in Julia; source paths below are
research evidence, not code to translate or embed.

## Priorities from the attached requirements

`ShenScope_Full_Development_Execution_Prompt.md` lines 69–81 name the primary
agents: **Codex, OpenCode, DeepSeek Harness, Pi, Kimi Code, ZCode, Qwen Code**.
The current user's request to comprehensively combine their strengths governs
implementation. The attached documents supply product context and provenance.

The same document lines 83–94 name Aider, Serena and CodeGraph for project data;
lines 96–101 name Aries and Hermes for dynamic computing. Lines 103–106 describe
Cline, Goose, OpenHands and SWE-agent as supplementary references when relevant.
Goose also appears in the Handoff V3 project list at line 163. These supplementary
projects do not replace the primary agents or establish that primary-agent
research is complete. Continue and further programmatic-compute references
mentioned in the history remain to be evaluated; they are not falsely counted
among the 22 currently pinned checkouts.

## Primary-agent source-to-behavior record

Revisions, repository URLs, licenses and inspected paths are pinned in
`reference_lockfile.json`. Test names below refer to executable repository tests.
The listed behavior covers specific observations, not all upstream advantages.

| Primary agent | Actual source observation | Independent Julia behavior and verification | Material work still missing |
|---|---|---|---|
| Codex | `core/src/guardian/request_budget.rs` estimates assembled history, instructions and tool metadata; `ext/agent-message-board/src/api.rs` separates durable acceptance from read acknowledgement, scopes caller membership and bounds paging | `Models/Requests.jl` estimates assembled requests; `Security/Budgets.jl` shares reservations; parent/child identity and concurrent accounting tests in `unit/foundation.jl`; workflow scope and bounded detached pages in `unit/tasks.jl` | Real OS sandbox integration, full approval modes, retained-evidence restoration, message-board subscriptions/tombstones and mature TUI workflow |
| OpenCode | `session/llm/native-request.ts` retains provider continuation metadata; `tool/task.ts` creates child sessions, derives permissions, limits recursion and supports background jobs | Native reasoning is replayed only to its compatible provider/model in `integration/providers.jl`; `Tasks/Executor.jl` creates an attempt-owned model session with shared parent policy/budget; task tools are absent from worker toolkits; async jobs and scoped approval tests in `unit/task_protocol.jl` | Configurable narrowed child profiles, ACP, plugin lifecycle, full LSP/MCP, provider discovery/routing and structured compaction |
| DeepSeek Harness | `core/agent-loop/src/tool-calls.ts` separates parallel work and exclusive barriers; `experimental/agent-team/src/task-graph.ts`, `task-board.ts` and `task-view.ts` validate dependencies, own revisions and derive readiness; `mailbox.ts` durably queues and separately acknowledges target acceptance | `Runtime/ToolScheduler.jl` uses bounded pools/barriers; `Tasks/Graph.jl` independently validates DAGs with iterative Kahn traversal and local descendant updates; CAS, cancellation, priority, leases and actual two-process claim tests | Advisory path-overlap views, graph editing, task ownership roles, mailboxes and target-side acknowledgement are still absent. Journal lifetime locking differs from execution TTL leasing |
| Pi / pi-mono | Agent loop separates internal events/model projection; session manager retains branches; durable harness output bounds streams independently of task results | Typed Julia messages/events, provider projections, durable session branches and bounded process logs; `Tasks/Results.jl` separately bounds result storage, hashes archived JSON and binds only declared predecessor results; actual DAG/artifact tests | Extension UI/commands, pinned extension package lifecycle, rich branch navigation and grounded model compaction |
| Kimi Code | `agent-core-v2/src/agent/loop/machine/requester.ts` gates requests and composes cancellation | Request validation/native reasoning, request-time credential snapshots, linked cancellation contexts and cancellation/partial-stream tests | Rich trust profiles, multimedia, ACP/marketplace, composed hook lifecycle and additional error-recovery policies |
| ZCode | `core/src/runtime/methods/turn-loop.ts` separates queued guidance, steering and context refill | `Core/AgentLoop.jl` applies bounded steering at turn boundaries, retains unresolved tool pairs, reports repeated identical result batches; Core protocol owns start/steer/cancel | Refill-density controls, richer plan/queued-prompt semantics and mature CLI/desktop command parity |
| Qwen Code | `core/src/providers/provider-config.ts` keeps protocol-dependent options/capabilities | Five separate native streaming protocols, bounded arguments, compatible reasoning replay and protocol-specific request validation verified by actual local HTTP fixtures | Model catalog/routing, plan/agent/channel modes, hooks/skills/MCP/LSP and broad daemon/SDK workflows |

## Durable task checkpoint design

The task implementation combines graph validation/readiness from DeepSeek,
independent model sessions and recursion limits from OpenCode, request-wide
accounting from Codex, and output ownership/bounds from Pi. The SDK lease review
adds token/generation fencing; Hermes/Goose reviews provide supplementary
operational observations. They are not substitutes for the primary sources.

ShenScope stores its own task specs and checksummed transactional event records.
Workers must prove a live execution lease before recording completion. Unknown
effects remain uncertain rather than being automatically replayed. Only a fixed
set of declared read operations can opt into automatic retries. Independent
Julia dispatch handles tool/test/index/analysis/model work, using existing Core
permissions and parent budgets. There is no claim of exactly-once external
effects, OS isolation, or complete upstream synthesis.

Future checkpoints must extend the primary rows with actual source observations,
behavior and tests, and close the remaining capabilities across applicable
projects in `capability_matrix.md`. Listing more projects alone is not progress.

## MCP source observations and independent behavior

All paths below were read from the pinned checkouts. This checkpoint extends
the primary reviews; it does not claim a full review of any repository.

| Source | Observation | Independent Julia behavior / verification | Remaining gap |
|---|---|---|---|
| Codex `rmcp-client/src/bounded_stdio_transport.rs`, `streamable_http_retry.rs` | Bound each stdio message and serialize writes; startup retry is distinct from arbitrary call replay | `MCP/Stdio.jl` strictly bounds line accumulation and serializes writes; `mcp_failures.jl` sends actual oversize/malformed output; HTTP failing calls issue one POST | OAuth refresh and interoperability behavior; ShenScope intentionally fails malformed stdout instead of skipping it |
| OpenCode `mcp/catalog.ts`, `mcp/index.ts` | Paged discovery checks cursor cycles; catalog refresh and notifications guard connection generations | Atomic catalog publication, repeated cursor rejection and generation/revision fencing; actual paged fixture, catalog-race and old-callback tests | ACP/MCP transport parity and discovery density policies |
| DeepSeek `mcp-client/src/connection.ts`, `tools.ts` | Confirm old transport closure; share an outage limit through flapping; retain server/raw-name identity while registering bounded aliases | Owned close barrier, stable-interval supervisor and hashed raw-name aliases; actual flapping process reaches its attempt limit without call replay | Registry rollback and server package/plugin lifecycle |
| Pi `mcp/src/protocol/jsonrpc.ts`, `transports/streamable-http.ts`, `client.ts` | Separate request/notification/response envelopes; SSE event IDs include priming events; gate discovery by capabilities | Strict bounded envelopes, JSON/SSE responses, optional GET listener and event-ID tracking; fragmented decoder tests and actual HTTP sessions | Request replay/resumption is deliberately absent; broader server-initiated capabilities remain pending |
| Kimi `sessionMcpHandle.ts`, `connection-manager.ts`, `mcpDiscoveryOps.ts`, `agent/mcp/output.ts` | Session connection views differ from global registry; discovery tracks full definitions/collisions; structured metadata and media need explicit preservation | Session-scoped resident managers and hashed declaration identity; structured content/metadata preserved and validated; agent and ownership tests | OAuth, deferred selection, native multimodal model delivery and durable discovery events remain absent |
| ZCode `adapters/src/mcp/stdio-transport.ts` | Process-tree cleanup and session identity belong to the transport's lifetime | Independent Linux owned process groups, startup PID capture, owned cancellation and scoped connection cleanup | Windows Job Objects are not implemented; no Windows verification claim |
| Qwen `tools/mcp-pool-entry.ts`, `mcp-retry.ts` | Pool seats and draining matter; typed cancellation/permanent errors should bound retries. Current pool file explicitly says some reconnect options are not consumed | Bounded session clients/jobs and drainage; no POST/tool replay; concrete implemented supervisor with outage tests | Full pooling/idle selection and OAuth. Configuration fields in a reference are not counted as working upstream behavior |
| JuliaMCP `src/mcp_protocol.jl` | Startup and tool timeouts differ; roots/progress/subscriptions support a persistent Julia server | Separate connect/request limits, permissioned roots, request-token progress and subscriptions; actual child fixture tests | Running a real JuliaMCP kernel and native IDE Julia debugger integration remain pending |

Implementation and limits: `docs/core/mcp.md`. The custom Julia schema checker,
state machine and transports follow independent Core types and permissions;
no SDK source or upstream algorithms are copied or translated.
