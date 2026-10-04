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

## Skills source observations

The pinned primary sources were read before the independent Skills implementation.
These remain partial reviews, not claims that every upstream feature is included.

| Primary source | Observation | Independent Core behavior | Remaining gap |
|---|---|---|---|
| Codex `ext/skills/src/loader/discovery.rs` | Traversal/inventory limits and metadata discovery distinguish complete from truncated results | Explicit entry/depth/catalog caps and visible truncation; metadata and bodies remain separate | Streaming directory enumeration, plugin namespaces and concurrent inventory |
| Pi `coding-agent/src/core/skills.ts`, `utils/frontmatter.ts` | SKILL.md roots stop recursion; diagnostics accompany metadata; invocation flags control listings | Deterministic root precedence, root recursion stop, strict bounded YAML metadata, lazy model listing | Ignore-file syntax and symlink imports; strict names differ from Pi's warning-tolerant behavior |
| OpenCode `skill/index.ts`, both `skill/discovery.ts` files | Multiple user/project sources; remote catalogs validate names/relative paths and source identity | User/project configured roots, protected confined resource paths and full source hashes | Remote catalog download/version activation is not implemented; no directory backups are introduced |
| DeepSeek `api/session-controller/src/skill-catalog.ts` | Metadata is cold-readable by session identity without activating an agent | Session-owned async metadata jobs and cached query; no model run needed for editor discovery | Preset/plugin composition and remote catalog transports |
| Kimi `features/skill/catalog/registry.ts` | Catalog identity/source grouping, model visibility and argument expansion are distinct concerns | Stable source IDs, explicit source selection, model/user invocation flags and bounded literal arguments | Plugin qualification, positional parameters and dialect-specific expansion |
| ZCode `shared/src/skills-types.ts` | Source paths, scopes, enabled state and diagnostics are part of client parity | Shared Core-backed user/project editor cards and permissioned source-opening proof | Symlink import/delete semantics and extension marketplace |
| Qwen `skills/skill-manager.ts`, `skills/types.ts` | Refresh completion ordering, invocation visibility and allowed-tools effects require explicit semantics | Atomic refresh publication, post-approval hash recheck, session restoration, declaration narrowing without permission grants | Watchers, implicit hook registration, richer matching and skill-directed routing |

Executable verification lives in unit/skills.jl, unit/skills_protocol.jl and
integration/skills.jl. Source hashes, schema restrictions and ownership are
implemented using ShenScope's own types and policies. YAML.jl is a general parser
dependency, excluded from authored Core counts. See docs/core/skills.md.

## Hooks source synthesis

All seven primary agent lines were read again before Hook implementation. These
are partial source reviews, not claims of complete upstream feature coverage.

| Source | Behavior examined | Independent Core decision | Remaining differences |
|---|---|---|---|
| Codex command runner | Owned child runtime, bounded asynchronous seats, environment restrictions and Windows Job Objects | Shared process ownership, eight command slots, cancellation and bounded capture | Fire-and-forget hooks, spill artifacts and Windows Job Objects remain pending |
| DeepSeek Harness protocol/runner | Paired invoked/result events, dialect-fenced decisions, stdin, cancellation and controlled failures | One small strict JSON protocol, metadata-only inputs, public result pairs | Claude/Codex dialect adapters and regex matcher compatibility remain pending |
| OpenCode plugin interface/trigger | Ordered lifecycle interception, tool and model/system transforms | Explicit named points and bounded opt-in context; completed tool results remain evidence | Arbitrary argument/header/result rewriting and plugin package hooks remain pending |
| Pi extension runner/types | Snapshot dispatch, before-tool blocking, result changes and failure isolation | Before-effect denial, stop after recording batch results, separate post-effect failures | Dynamic extension handlers, structured-result replacement and custom UI hooks remain pending |
| Kimi external hook types/service | Typed session/tool/turn/compaction events, tool veto, observable hook results | Shared agent/worker points, controlled observable outcomes and session ownership | Heartbeats, compaction and broad event integrations remain pending |
| ZCode configured runner | Source admission, declaration fingerprints, enabled flags, timeout/output bounds | Source/declaration hash targets rechecked after approval, explicit reload and enable controls | Full plugin admission and workspace hook dialects remain pending |
| Qwen hook types | Project/user/system source types, broad event vocabulary and pre/post-write distinction | Explicit project/user/inline scopes and separation of before decisions from after observations | HTTP hooks, additional scopes and complete event vocabulary remain pending |

Hook commands are not translated upstream code. Core uses Julia ScopedValue for
owned lifecycle context, Task/Channel cancellation paths and ordinary dispatch
interfaces. Durable task receipts persist potential Hook effects before launch;
workflow effect barriers and lease recovery prevent implicit replay. Tests cover
actual processes, permission/source races, agent context, worker effects and both
client controls. Host commands still require future OS isolation; no Windows or
live-model result is inferred from Linux fixtures.

## Context source synthesis

The seven primary agents were reviewed again for request preparation, compaction
and evidence recovery. The paths are pinned in the lockfile. This extends partial
reviews; it does not establish complete upstream coverage or reuse their code.

| Source | Behavior examined | Independent Julia behavior | Remaining differences |
|---|---|---|---|
| Codex `compact.rs`, `compact_token_budget.rs`, `context_manager/history.rs` | Request-wide capacity, older history and bounded compaction decisions | Provider-native wire accounting, output reservation, balanced tool rounds, strictly smaller recovery requests | Exact tokenizer, upstream compaction hooks and broad multimodal history policies |
| OpenCode `session/compaction.ts`, `instruction-context.ts` | Retained context, summary instructions and scoped project instruction refresh | Immutable transcript projections, explicit scoped instruction sources and optional no-tool summaries | Watching, conditional instruction matching, richer resume prompts and plugin transforms |
| DeepSeek `compaction/src/types.ts`, `index.ts`, tool-result pruner | Separate compaction/pruning provenance, complete ranges and shadowed outputs | Checkpoint prefix/source hashes, read-back evidence and deterministic tool previews | Durable pruning event dialects, richer working sets and selection policies |
| Pi `core/compaction/compaction.ts`, `utils.ts` | Recent context, file-operation awareness, usage and compaction boundaries | Whole-group selection, current user goal retention, source metadata and actual request accounting | Full branch UI, custom summary hooks and package extension behaviors |
| Kimi compaction controller, context recovery and workspace instruction service | Explicit reasons/attempt state, retained evidence pointers and instruction reload | Bounded classified overflow recovery, attempt accounting and digest-checked source/artifact reads | Broader journal recovery workflows, multimodal and watched instructions |
| ZCode `compact/rounds.ts`, `policy.ts`, `microcompact.ts` | Round boundaries, output reserve and request-density controls | Tool-pair validation, pinned incomplete rounds and conservative fixed-input failure | Refill density and no-progress circuit policies |
| Qwen input slimming, chat compression and rule discovery | Media/metadata preservation, language-sensitive capacity and conditional sources | Native protocol measurement, Chinese/emoji estimation and clearly scoped instruction text | Media slimming, exact token counting and conditional rule/glob discovery |

Core tests verify original journal retention, tampered/foreign evidence rejection,
post-approval checks, structured summary failures and usage charging, five actual
HTTP protocols, no recovery after partial reasoning/tool output and UTF-8 process
events. Editor flows use Core ownership and permissions. Source identity is
verified; model summary prose is not claimed to be independently proven.
See `docs/core/context.md` for limits and executable commands.

## Semantic project data source synthesis

The V3 continuation's P2 requirement specifies an actual TypeScript compiler or
language-server semantic path. The execution prompt requires stable backend
facts, local deltas and 1/5/20-file full rebuild oracles. The following source
sections were read before/during this implementation, not copied or translated.
Paths are pinned in the lockfile; these are bounded partial reviews.

| Source | Inspected behavior | Independent Julia implementation | Remaining scope |
|---|---|---|---|
| OpenCode `lsp/client.ts`, `tool/lsp.ts` | UTF-16 positions, synchronized documents, definition/reference/type/call operations and permissioned source access | Validated SourceMap conversion, explicit capability gating, committed source digests and permissioned navigation | Generic LSP sync/registrations and multiple language servers |
| DeepSeek `lsp-stdio/src/framing.ts`, `docs/subsystems/lsp.md` | Bounded framing, capability service separation, workspace URI/position normalization and cancellation | Closed compiler protocol, strict response ownership/identity, bounded request pipes and linked runtime cancellation | Full LSP transport/provider federation |
| Qwen `LspResponseNormalizer.ts`, `native-lsp-service.ts` | Diagnostic normalization, document versions, source ownership and response freshness | Core-normalized diagnostic/range schema, whole-input/configuration digest, revision/source guards | General LSP clients, related diagnostic information and native Problems |
| Serena TypeScript language-server adapter | Version-pinned dependencies and distinction between service readiness, indexing and failed startup | Pinned real TypeScript checker, controlled process/config failures and complete snapshot commit | Other languages, asynchronous server indexing readiness and rename; GPL source remains research only |
| Codex deferred `tool_search.rs`, `tool_search_spec.rs` | Metadata cache identity, bounded descriptions and discovery separate from execution | Project capability metadata, explicit bounded navigation/tool schema and unchanged existing lazy working-set behavior | Broader dynamic tool discovery/cache invalidation; no Codex LSP observation is claimed |
| Pi `tools/read.ts` | Injectable bounded source reads and cancellation | Bounded approved source snapshots with source identity checks | Broader remote/read-operation extension hooks |
| Kimi `tools/os/read/read.ts` | Bounded character reads, cursor units and continuation | Explicit UTF-8/UTF-16 input units and bounded evidence pages | Remote/multimedia read operations |
| ZCode `read-file-state.ts` | Normalized read ownership and latest-source freshness | Verified snapshot source digest before cursor navigation and optional caller digest/revision | Automatic watchers and stale-aware editor mutations |

Julia implements resident graph identity, occurrences, metadata, strict compiler
normalization, transactional source rechecks and navigation over ordinary typed
data. The helper uses the installed TypeScript checker only for compiler facts.
Static checker links retain their provenance and unresolved counts; runtime
dispatch completeness is not inferred. Existing analyzers run unchanged over
the fourth backend. Real compiler/transport/RPC tests and both editor clients
verify the documented path. Compiler checking remains global after input changes;
the small-fixture oracle establishes correctness, not competitive performance.
See `docs/core/semantic.md` and checkpoint 013 for precise limits/evidence.

## Derived index lifecycle and change monitoring

Checkpoint 014 applies bounded partial reviews of the following source sections.
They inform storage and the next watcher milestone; they are not copied or
translated. Conversation compaction and process observation are distinguished
from project graph storage and filesystem observation.

| Source | Observed behavior | Independent Core consequence | Remaining scope |
|---|---|---|---|
| Kimi `minidb/src/snapshot.ts` | Live-entry snapshots, cooperative yielding, byte chunks and complete writes | Stream one current project snapshot, cap output, verify write progress, preserve logical revision | Large-graph memory/durability measurements |
| Qwen `managed-session-record-sink.ts` | Compacted range and activation sequence applied at commit | Commit publication remains the visibility boundary for derived facts | Conversation archive integration is separate |
| ZCode `read-file-state.ts` | Latest observed source ownership and freshness | Physical journal identity fences stale writers even at unchanged logical revision | Watched editor mutations |
| Pi `utils/fs-watch.ts` | Explicit close/error handling and failed-start/retry behavior | Next watcher needs owned resources and observable failure/stop | Watch implementation pending after checkpoint 014 |
| OpenCode file watcher and filesystem event schema | Normalized add/change/delete paths, cache invalidation and loaded directory refresh | Next watcher coalesces scoped changes and exposes dirty state to both clients | Watched source and configuration integration |
| DeepSeek `fs` and `fs-local` | Provider-scoped containment, readiness/error/abort lifecycle | Monitor hints must preserve Core workspace ownership and cancellation | Recursive change convergence and lifecycle tests |
| Codex `unified_exec/async_watcher.rs` | Bounded event delivery, cancellation and notification registration | Bounded wakeups and owned cancellation inform the next worker | This source observes process output, not files |
| JuliaMCP `watcher.jl` | Recursive snapshots and quiet-window batches | Next graph watcher advances its applied baseline only after a successful transaction | Stable batches, syntax failures and native hint validation |

Checkpoint 014 verifies streaming replay, atomic compaction, stale-writer fencing,
hard-killed staging cleanup and actual compiler/CLI/RPC/editor flows. It does not
establish watcher functionality, Windows durability or large-project performance.

Checkpoint 015 implements owned monitoring, periodic recursive content checks,
single-slot wakeups, a distinct settling timer, retained failure fingerprints,
scoped asynchronous RPC and shared editor controls. Additional inspected sources:
Codex `app-server/src/fs_watch.rs` (connection/watch ownership and drained unwatch),
ZCode `fileWatcher/fileWatcherService.ts` (coalesced paths and timer/emitter cleanup),
Qwen `lsp-config-watcher.ts` (invalid configuration preserves current runtime),
and DeepSeek `fs-local/src/index.ts` lines 64–93 (ready/abort/error/close and explicit
provider containment caveat). Julia independently supplies hashing, journal
transaction reuse, baseline confirmation and policy/budget ownership. Its RPC
stop acknowledges cancellation first and publishes final retirement after drain.
Native hints are root-only; recursive content scans supply convergence. Twelve
real 1/5/20-file watch/full-fact oracles and actual TypeScript configuration/scope
tests cover the selected behavior. These remain partial reviews and small Linux
evidence, not a complete synthesis of every upstream advantage or a performance
claim. Native retry/backpressure enhancements and larger projects remain future
research. The Core target is still unmet.
