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

## Isolated analyzer checkpoint source observations

Checkpoint 016 revisits all seven primary agents and the Julia-specific
references. These are selected source reviews. No implementation is copied or
translated, and no full upstream synthesis is claimed.

| Source read | Design observation | Independent implementation or remaining difference |
|---|---|---|
| Codex `linux-sandbox/src/landlock.rs` | Filesystem enforcement, synchronized seccomp and no-new-privileges are OS concerns | Compute-specific default-deny seccomp after trusted bootstrap, descriptor/mapping audit and direct-call tests; workspace-write tool isolation remains pending |
| OpenCode `plugin/loader.ts` | Resolution, compatibility, loading and operational failure have separate stages | Candidate registration, method contract, selftest, external validation and evaluation are distinct; installable package lifecycle is pending |
| DeepSeek `fs-sandbox/src/containment.ts` | Canonical paths and filesystem identity matter | Bounded confined source reads, symlink rejection and launcher/source identity checks; platform-specific filesystem sandbox policy remains pending |
| Pi `coding-agent/examples/extensions/sandbox/index.ts` | Extension execution combines OS restrictions with timeout, cancellation and output ownership | Owned bounded compute process, linked cancellation and shared budget; arbitrary extension commands are not covered by this compute profile |
| Kimi `runtime/runtimeUnitHost.ts`, `runtimeRegistry.ts` | Generations stage publication and own resources through retirement | Session-owned candidate versions, explicit selection and bounded in-flight leases; full generation draining/package lifecycle is pending |
| ZCode `core/src/repl/node-repl-session.ts`, `contracts/src/tools/eval-workflow-snippet.ts` | Generated producer metadata is untrusted; snippets have explicit source and output contracts | Parent-owned identity, independent fixture comparison, strict frames and untrusted timing labels; richer REPL/browser features remain pending |
| Qwen `cli/src/config/extension-runtime-reload.ts`, `execution-sandbox-settings.ts` | Reload phases and operator sandbox policy have explicit semantics | Registration does not replace selected code; failed isolation rejects evaluation; general tool policy and package reload remain pending |
| Kaimon `src/kaimon_eval.jl`; AgentREPL `src/tools.jl`; JuliaMCP `src/tool_handlers.jl` | Evaluation requires bounded output and explicit worker/runtime contracts | Child Module with `invokelatest`, structured results and kernel restrictions; persistent trusted REPL introspection is a separate extension surface |

Handoff V3 sections 12.3/14.6 and IDE continuation V3 sections 19/34/35 govern
these contracts. Historical claims of six analyzers and Linux seccomp evidence
are not imported as current results. Checkpoint 016 records runnable evidence;
graph provenance, archive/promotion/rollback and dedicated editor controls are
implemented in checkpoint 017 and validated separately.

Checkpoint 017 extends those selected observations with independent Julia
implementation: detached backend-neutral graph snapshots, parent-owned fact
identity/provenance, external-fixture receipts, immutable JSON version manifests,
separate CAS active-pointer revisions, fresh validation on promotion/rollback,
bounded asynchronous job ownership and shared native/VSIX controls. Kimi's
generation/lease observation informs ownership and explicit publication; Qwen's
separate reload stages inform admission versus selection. The archive schema,
CAS policy and graph evidence constraints are ShenScope's own design derived
from Handoff V3 section 12.3 and continuation V3 sections 19/34/35, not translated
upstream implementations. Package lifecycle, general tool isolation, trusted
persistent Julia REPL integration and full upstream synthesis remain incomplete.

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


## Provider directory and counting synthesis

Checkpoint 018 reviews selected source sections in every primary agent, at the
revisions recorded in `reference_lockfile.json`. This is additional partial
source evidence, not a claim that each project has been comprehensively read.
All directory, HTTP, counting and ownership code is independently authored Julia.

| Primary source | Observed design | ShenScope implementation | Remaining scope |
|---|---|---|---|
| Codex `context/world_state/model_catalog.rs` | Bounded stable catalogs and display eligibility should not rewrite prior context | Directory discovery is explicit and never replaces configured selection or history | Picker eligibility and historical shown-catalog integration |
| OpenCode `provider/provider.ts` model schema | Provider identity, wire configuration, feature declarations and limits are separate fields | Protocol/source identity and field provenance; input/context/output limits separate | Provider presets, transforms, pricing and routing |
| DeepSeek Harness `llm-pi-ai/src/catalog.ts` | Strict/deferred validation, field overrides and duplicate-ID invalidation | Per-entry diagnostics, duplicate invalidation including malformed duplicates, atomic page publication | Deferred profile activation and effective override resolution |
| Pi `models-store.ts`, `models.ts` | Snapshot ownership, check time/ETag, effective credentials and abort signals | Conversation/source/credential-scoped snapshots, single-page validators and cancellation | Durable cache, configurable listing strategies and import/export |
| Kimi `modelsDevImport.ts` | Imported endpoint/model declarations retain reasons and explicit capability metadata | Unknown capabilities stay unknown; no name-based capability or cost guesses | Reviewed catalog import and provider dialect policies |
| ZCode `runtime/model-selection.ts` | Provider/model/options belong to an explicit selection value | Configured model and discovered directory remain separate immutable reports | Role routing and selected-option compatibility |
| Qwen `model-catalog-refresh.ts` | Bundled/remote freshness, normalized conflicts, positive limits and absent modality semantics | Bounded TTL cache, invalid-ID exclusion, finite positive declared capacities | Bundled catalog reconciliation and multimodal declarations |

Actual Anthropic/Gemini token-count bodies are built from the same Core request
assemblers as inference, with immutable logical-request credentials. Other
protocols receive a clearly labeled local heuristic when `auto` is used; 404 is
an explicit fallback, while auth/malformed/transport failures remain visible.
Counts are not inference usage or evidence of tokenizer/billing exactness.
Core API and both actual editor clients exercise owned jobs and permissions.
See `docs/core/models.md` and checkpoint 018 validation for precise evidence.

## Retry and provider-health synthesis

Checkpoint 019 adds selected source observations at the pinned revisions. These
are partial reviews, not a claim that entire projects have been comprehensively
read. The circuit implementation is an independent Julia design; the sources
below are not claimed to implement the same circuit state machine.

| Primary source | Observed design | Independently implemented boundary |
|---|---|---|
| Codex `responses_retry.rs`, `compact_model_fallback.rs` | Typed terminal failures, bounded retry state and explicit compaction fallback | Cancellation/budget remain terminal; retry reasons are observable and never extend limits |
| OpenCode `session/retry.ts` | Bounded jitter, header advice and user-visible retry reasons | Valid server waits are floors; suppression is explicit when the wait exceeds limits |
| DeepSeek Harness `llm/src/retry-policy.ts` | Provider-owned immutable retry policy and transient classification | Strict bounded Core policy; always/infinite retry modes are not implemented |
| Pi `utils/provider-retry.ts` | Server veto and delay precedence, excessive-wait rejection | False advice vetoes; true advice cannot override terminal categories; excessive waits suppress |
| Kimi requester and base retry utilities | Abort-aware waits and terminal abort/quota/context/filter categories | Shared cancellation/permission/budget checkpoints during waiting and blocked reads |
| ZCode `subagent/profile-model-selection.ts` | Explicit provider/model/options selection boundaries | Logical body/key snapshots and retained provider runtime; role selection remains next work |
| Qwen `utils/retryPolicy.ts` | Exponent/timer ceilings and server-delay handling | Saturated exponent arithmetic with finite policy waits and shared deadline admission |

Core adds scoped bounded logical-request leases, mutex/epoch circuit transitions,
one explicit half-open inference probe, neutral non-provider outcomes and CAS
reset with no hidden network request. Server, task workers, CLI/TUI and Models
services share the intended runtime lifetime. Both actual editor clients expose
cooldown, admission state and the last observed outcome. See
`docs/core/model_policy.md` and checkpoint 019 evidence. Persistent fleet health,
automatic role routing and live-provider availability claims are not implemented
by this checkpoint.

## Explicit role-route synthesis

Checkpoint 020 reads selected role/model configuration boundaries in all seven
primary references. These observations remain partial, pinned source evidence.
Core's provider/profile/role planner and fleet runtime are independently authored
Julia and do not translate or embed those implementations.

| Primary source | Observed advantage | Core application and current boundary |
|---|---|---|
| Codex `agent-roles/src/agent_role_config.rs` | Role metadata and resolved configuration are distinct, with strict normalization | Named role routes and strict referenced profiles; role prompts/config-file imports remain separate work |
| OpenCode `config/agent.ts` | Agent declarations are loaded and validated at a clear configuration boundary | Fleet validation precedes config-file replacement; Markdown agent imports are not implemented here |
| DeepSeek Harness `agent-team/src/roster.ts` | Root/teammate identity, explicit provider and inherited model are observable without conflating ownership | Shared configured source runtime, explicit optional worker role and conversation-owned receipts; durable teams remain separate |
| Pi `coding-agent/src/core/model-config.ts` | Credential-blind immutable configuration, declared compatibility/routing options | Canonical immutable profile options, credential-free planning and prepared logical snapshots; provider dialect presets remain pending |
| Kimi `contract/global/models.ts` | Wire protocol, provider identity, concrete model and capability overrides are independent fields | Typed source/profile selection with explicit capacity/feature overrides; OAuth/import reconciliation remain pending |
| ZCode `shared/src/model-selection.ts` | Structured provider/model/options selection; picker strings are display boundaries | Structured selections and explicit role/profile RPC/CLI fields; no model identity is reconstructed from UI display strings |
| Qwen `subagents/types.ts`, `agent-frontmatter-schema.ts` | Inheritance/fast/explicit selectors and subagent-only permission distinctions | A declared worker route inherits the default when absent; model profiles cannot change permission policy; fast aliases and declarative agent imports remain pending |

Planning reports actual wire/context and native replay exclusions before keys or
network. All eligible keys are captured before approval; typed transient fallback
stops after delivery. Conservative role capacity/price admission, bounded shared
circuits and private conversation receipts support both actual editor clients,
CLI and RPC. This is explicit routing, not an automatic model-quality ranking or
evidence of faster/cheaper live inference. See `docs/core/model_routing.md` and
checkpoint 020 validation for precise evidence and remaining scope.
# Git history and evidence analysis — checkpoint 021

Selected source review precedes independent implementation. Codex's
`utils/git-discovery` emphasizes bounded probe ownership; ShenScope uses the
existing conversation-owned project job and local process lifecycle. OpenCode's
typed repository/change/error interfaces inform explicit snapshot geometry.
DeepSeek Harness's workspace-changes runner supplies design questions around
timeouts, cancellation, stdout loss and environment scrubbing; its snapshot
copy workflow is not used. Pi's bash lifecycle is reviewed for cancellation
and timeout behavior; ShenScope Git uses argv rather than shell commands.
Kimi's work-tree geometry illustrates Git-directory pointers, which this first
scope rejects rather than following external metadata. ZCode's Git service
interfaces distinguish typed read results and changes. Qwen's review wrapper
motivates fresh environment capture and config/discovery guards; its disposable
worktree flow is not used.

Serena's separate commit/staged/unstaged observations reinforce explicit history
coverage. Aider's definition/reference ranking illustrates evidence-driven file
selection; no PageRank implementation is copied or translated. ShenScope's
co-change support, exact-path project join and declared review heuristic are
independent Julia implementations with full commit evidence and explicit limits.
All seven primary agent reviews remain partial; this checkpoint does not claim
complete synthesis, calibrated risk or model-quality improvements.

## Migration and graph coverage — checkpoint 022

Codex plan-tool statuses inform the distinction between a proposal and completed
work. DeepSeek Harness task-graph validation contributes dependency/cycle design
questions; its recursive validator is not translated. OpenCode LSP exposes
recorded definitions, references and call hierarchy with scope checks. Kimi's
todo updates separate observed state from optional mutations. Pi's exact-edit
contract reinforces that a graph proposal cannot substitute for guarded source
edits. ZCode's plan-guidance UI keeps evidence/readability separate from checklist
status. Qwen's captured-diff plan keeps proposal identity tied to concrete input.
Selected paths are in the research lockfile; all reviews remain partial.

Independent Julia graph algorithms now supply validated iterative SCCs for both
Architecture and Migration, deterministic dependency layers, source/index/seed
identity and bounded relation/test evidence. The analyzer graph snapshot is reused,
and depth-boundary omissions now correctly mark ordinary traversal as partial.
Real Go AST, Tree-sitter, CodeGraph and TypeScript compiler fixtures verify the
shared planner. No upstream implementation, review-agent topology or worktree
copy workflow is reused. No safe-migration, calibrated-confidence or performance
improvement claim follows from these facts.

## Startup checkpoint 023

Selected source reads revisit all seven primary agents; the review remains
partial. Codex's CLI separates subcommand ownership; OpenCode's serve command
loads its server at its command boundary; DeepSeek's public CLI and desktop
launcher distinguish mode selection and installation-owned dependencies. Pi's
small entry point separates setup/main. Kimi's command handler returns an outcome
to the process owner. ZCode establishes protocol stdout/stderr boundaries before
bootstrap. Qwen measures its entry baseline before route-specific imports.
Paths and revisions are in the lockfile.

Julia has different compilation semantics: independently authored command and
RPC boundaries use `Base.invokelatest`, and a disposable offline PrecompileTools
workload captures metadata methods. The implementation preserves framed stdout,
permissions and controller ownership. Measurements separate explicit cache
generation from new-process readiness. A first agent turn remains substantially
slower than initialization. See `../core/startup.md` and checkpoint 023 evidence;
no upstream code or bootstrap implementation is translated. PackageCompiler,
clean-machine/installed distribution and cross-platform timings remain pending.

## Scoped memory checkpoint source observations

Checkpoint 024 read selected portions of all seven primary checkouts. No row
claims a complete repository review, code reuse or a line-by-line translation.

| Project / inspected path | Observation | Independent Julia behavior |
| --- | --- | --- |
| Codex `codex-rs/protocol/src/memory_citation.rs` | Citation carries source range/note and rollout identity | Stored version/hash/snapshot citations and original UTF-8 lexical witness spans; file fact verification remains pending |
| OpenCode `packages/core/src/instruction-context.ts` | Instruction context tracks its boundary and registry ownership | Explicit root/state/owner/namespace checks and immutable snapshot identity |
| DeepSeek Harness `packages/compaction/compaction-tool-result-pruner/src/types.ts` | Bounded replacement text retains source/replacement sequence accounting | Character-clipped excerpts, bounded evidence lists and explicit omissions while durable versions remain available |
| Pi `packages/durable/src/harness/compaction.ts` | Compaction captures a kept boundary and request/context state | Pagination pins the captured query, scope, snapshot and expiry time |
| Kimi Code `packages/minidb/src/memory-guard.ts` | Retention policy accounts for bytes, TTL and capacity | Bounded snapshot/index input, bounded four-entry LRU, expiry visibility and disclosed partial coverage |
| ZCode `apps/zcode-cli/packages/core/src/memory/origin-session.ts` | Origin-session metadata is stamped with confined file handling | Declared origin session and source/reference fields with root proof and safe journal path checks |
| Qwen Code `integrations/external-context/src/memory-content.ts` | Content validation bounds Unicode text and rejects malformed surrogate input | UTF-8 validation, bounded text/metadata, exact witness coordinates and editor source disclosures |

The combined design uses Julia-owned journal validation, CAS, lexical BM25F and
conversation-owned jobs across CLI/TUI/native/VSIX. Scores are lexical relevance;
source declarations are not verified truth. Namespace admission and fact writes
are separate journals. General OS isolation and semantic memory remain pending.

## Execution security checkpoint source observations

Checkpoint 025 reads selected sections of the seven primary checkouts, extending
the existing partial reviews. It independently implements Julia policy, namespace
argument planning, child state, resource/network rules and scoped diagnostics.

| Project / source | Observation | Julia synthesis |
| --- | --- | --- |
| Codex `codex-rs/linux-sandbox/src/landlock.rs` | Current filesystem enforcement belongs to bubblewrap; syscall/network policy and no_new_privs are separate primitives | Namespace backend and separate Julia/libseccomp bootstrap, explicit host state, no unverified Landlock fallback |
| DeepSeek Harness `packages/sandbox/sandbox-policy/src/session-mode.ts`, `packages/sandbox/sandbox/src/diagnostics.ts` | Effective session policy and runner failures require owned state and structured evidence | Immutable launch policy, conversation-owned probe jobs, bounded failure diagnostics and no automatic host fallback |
| OpenCode `packages/opencode/src/permission/index.ts` | Pending requests are owned deferred decisions; rule evaluation has explicit Ask behavior | Existing Core approvals remain separate by Read/Edit/Process/Network and bind the captured execution declaration |
| Pi `packages/coding-agent/examples/extensions/sandbox/index.ts` | Command backend/environment integrates a filesystem and network policy | Explicit child state and filesystem/network options; no claim to implement Pi's domain allowlist |
| Kimi Code `packages/agent-core-v2/src/agent/permissionPolicy/policies/git-control-path-access-ask.ts` | Git control-path access is distinguished from ordinary files | Workspace Git metadata stays readonly; private Core state and secret-name paths are masked |
| ZCode `packages/shared/src/permission-request-preview.ts` | Permission previews identify command arguments and file scope | Process approval exposes argv/directory, readonly runtime paths, policy, limits and environment-key names |
| Qwen Code `packages/cli/src/config/execution-sandbox-settings.ts`, `packages/core/src/sandbox/bwrap-status.ts` | Strict backend/filesystem/network config and bounded evidence distinguish unconfirmed setup from payload exit | Pre-write config validation, nonce-bound setup receipts, explicit signal status and no claim that setup confirms payload exec |

Kernel network/resource/descriptor tests and interrupted durable file-effect tests
are actual native-process checks. Full namespace execution is blocked in this
container and its refusal is tested; the available-backend integration branch is
not counted as executed here. Native/VSIX diagnostics preserve that distinction.
Additional platform/domain policies, adapters and clean-machine validation remain
pending. No upstream implementation was copied or translated.

## Julia project evidence checkpoint source observations

Checkpoint 026 rereads handoff sections 9.2/9.3 and 18.1–18.4: replaceable fact
backends, language-specific semantics and Julia-owned analysis across evidence
sources. Selected source reads extend the partial review of all seven primary
agents; they do not establish complete upstream audits.

| Project / source sections | Observation | Independent Julia implementation |
| --- | --- | --- |
| Codex `codex-rs/file-search/src/lib.rs` lines 45–100 | Matches retain root/path/type and a separate total count | Source identities, scoped paths and bounded evidence pages remain distinct from ranking |
| OpenCode `packages/opencode/src/tool/lsp.ts` lines 1–70 | Navigation operations and source positions have explicit permission context | Existing navigation contracts plus independent Julia source actions; capability flags do not promise unsupported hover/references |
| DeepSeek Harness `packages/lsp/lsp-stdio/src/translate.ts` lines 1–50 | Protocol translation and capability checks are separate from I/O | JuliaSyntax facts normalize into existing Core symbols/ranges; no backend-private schema enters analyzers |
| Pi `packages/coding-agent/src/utils/syntax-highlight.ts` lines 1–65 | Highlight-language availability and plain text fallback are separate from code understanding | Source signature cards preserve readable text while disclosing absent compiler semantics |
| Kimi Code `packages/agent-core-v2/src/agent/tools/os/grep/grepTool.ts` lines 1–81 | Source search explicitly excludes credential/secret path families | Existing workspace/read gates and hash verification also guard Julia indexing and evidence queries |
| ZCode `packages/ui/src/ToolCallBlocks/renderers/search.tsx` lines 1–80 | Tool views normalize bounded human-readable query/target summaries | Both editors show source-linked method cards, human-readable axes and explicit confirmation requirements |
| Qwen Code `packages/cli/src/ui/commands/lspCommand.ts` lines 1–78 | Disabled/disconnected language services have different user-visible states | Julia syntax capability is reported separately from the TypeScript compiler backend; missing semantics are not inferred from syntax availability |

The JuliaSyntax dependency's parser and streaming raw-lexer APIs were inspected
directly before integration. Core uses the pinned package and independently
implements extraction, identities, scope handling, dispatch pattern comparison,
permissions, bounds, persistence and queries. It never loads project code. The
existing CodeGraphContext and non-Julia backends remain first-class capabilities;
compiler-confirmed Julia dispatch and cross-backend fusion remain open.

## Combined evidence checkpoint source observations

Checkpoint 027 rereads handoff multi-source/multiple-dispatch sections and the
Julia resource guidance. These selected reads continue the partial upstream
review; they do not claim every advantage of each project has been implemented.

| Project / inspected sections | Observation | Independent Core behavior |
| --- | --- | --- |
| Codex `codex-rs/file-search/src/lib.rs` 98–119 | Snapshot, total/scanned counts and completion differ | Combined pages expose total, offset, revision vector and bounded snapshot fingerprint |
| OpenCode `packages/opencode/src/lsp/lsp.ts` 417–437 | Symbol requests collect results from multiple clients | Julia keeps provider identities and separate facts instead of flattening away origin |
| DeepSeek Harness `packages/lsp/lsp-stdio/src/translate.ts` 50–72 | Advertised capability checks are explicit | Each evidence source retains its capability claims; anchors do not claim compiler semantics |
| Pi `packages/coding-agent/src/core/extensions/types.ts` 332–355 | Scoped models are read-only session views with cancellation context | Combined requests use owning session contexts and detached index captures |
| Kimi Code `packages/agent-core-v2/src/tool/output-accumulator.ts` 1–93 | Retained output and total output are distinct and truncation is visible | Evidence separately bounds serialized capture, selected page bytes and total observations |
| ZCode `packages/ui/src/ToolCallBlocks/renderers/search.tsx` 79–97 | Query/result summaries use normalized human-facing status | Shared IDE controls name sources and show signatures, witnesses and source links |
| Qwen Code `packages/core/src/lsp/LspResponseNormalizer.ts` 866–925 | Source/server identity, selection range and recursive symbol limits matter | Exact anchors require matching full source ranges and retain all provider observations |
| CodeGraphContext `api/schemas.py` 1–37 and `tools/indexing/schema_contract.py` 1–30 | Private graph labels/query structures form an adapter boundary | Combined analysis consumes existing neutral symbols/relations, not database schemas |
| Serena `src/serena/symbol.py` 258–277 | Identifier locations and body locations have different meanings | Range mismatch keeps independent declarations; no approximate bridge is silently inferred |

No implementation was copied or translated. Exact-source bridges, conflict
refusal, namespaced identities, bounded capture and dispatch on the combined
snapshot are authored Julia behavior. Git/coverage/runtime fusion and broader
compiler-confirmed semantics remain pending.

## Julia optional extension lifecycle source observations

Checkpoint 028 rereads the handoff's multiple-dispatch, invokelatest,
weakdeps/extensions, resource cleanup and precompilation guidance. Selected source
reads are capability observations, not complete upstream audits.

| Source | Observation | Independent Julia implementation |
| --- | --- | --- |
| Codex `codex-rs/core-plugin-common/src/plugin_id.rs` 1–65 | Stable identifier validation is separate from storage paths | Registry and contribution names reject traversal; UUIDs and generations retain identity |
| OpenCode `packages/opencode/src/plugin/loader.ts` 1–58 | Planned, resolved, loaded and stage-specific failures differ | Package receipts, inactive registration, activation, quarantine and cleanup receipts remain separate |
| DeepSeek Harness `packages/sdk/server/tests/plugin-shape.spec.ts` 1–29 | Plugin export shape is tested through the actual loader | Real Base.require and the named bundle function are tested against an independent Julia package |
| Pi `packages/coding-agent/src/core/extensions/loader.ts` 1–65 | Optional loader machinery is lazy and runtime-dependent | No automatic package installation; Pkg weakdep module loading and registry activation are independent |
| Kimi Code `packages/agent-core-v2/src/app/plugin/manifest.ts` 1–55 | Manifest candidates and unsupported runtime fields have explicit diagnostics | Exact installed UUID/version/hash receipts precede factory execution; unsupported interfaces refuse activation |
| ZCode `packages/ui/src/store/pluginStore.ts` 1–58 | Operations include workspace identity and shared pending state | Workspace scope, owned jobs and pending-operation controls guard both editors |
| Qwen Code `packages/core/src/tools/tool-registry.ts` 49–75 | Deferred parameter fingerprints matter separately from mutable prose | Reviewed schemas are frozen and compared; descriptions do not authorize argument changes |
| PromptingTools `Project.toml` 30–45 | Real Julia weakdeps and extensions are independent package declarations | SparseArrays activates an authored optional Core extension through Pkg's actual loader |
| Kaimon `src/extensions.jl` 1–42 | Namespace, module entry and shutdown callback have different responsibilities | Bundle identity, latest-world factory invocation and reverse cleanup callbacks are independently validated |

No upstream implementation was copied or translated. Trusted in-process loading
does not replace isolated analyzers or OS sandboxing. Persistent package
configuration, marketplace distribution, plugin host isolation and broad provider/
backend config registration remain pending.

## Terminal runtime source observations

Checkpoint 029 rereads the handoff Cmd/process/IO guidance and V3's native terminal
requirements. These selected reads remain a partial capability review.

| Source | Observation | Independent Julia behavior |
| --- | --- | --- |
| Codex `codex-rs/utils/pty/src/process.rs` 1–75 and `spawn_helper_tests.rs` 1–100 | Terminal size, signals, exec-helper readiness and descriptor inheritance need distinct contracts | A dedicated Julia bootstrap checks the controlling terminal; Core owns size, lifecycle, nonce receipt and real-child tests |
| OpenCode `packages/server/src/handlers/pty.ts` 1–95 | Workspace identity and terminal ownership precede access | Every handle/job binds one workspace and conversation; clients receive no direct host shell launcher |
| DeepSeek Harness `packages/terminal/tool-terminal/src/background.ts` 1–39 | Consuming output and monotonic byte cursors have different semantics | Retained filtered UTF-8 offsets, observed raw bytes and explicit loss are independent fields |
| Pi `packages/coding-agent/src/core/bash-executor.ts` 1–78 | Cancellation, truncation, sanitization and optional full-output files are independent choices | Core retains bounded output in memory and does not silently persist complete terminal transcripts |
| Kimi Code `packages/agent-core-v2/src/session/terminal/terminalService.ts` 1–85 | Scoped records separate process, client sinks, buffer and cleanup | Core owns the process; thin native/VSIX adapters attach bounded cursor readers and serialized input |
| ZCode `packages/ui/src/terminal/terminalDataTransform.ts` 1–55 | Terminal display normalization is platform-specific | Julia filters control strings and preserves common display escapes; unsupported platforms are declared rather than inferred |
| Qwen Code `packages/core/src/managed-runtime/local-shell-result-capture.ts` 1–75 | Observed bytes, retained segments, stream identity and completion differ | PTY streams explicitly merge; output floor, cursors, raw counts and completion remain inspectable |

No upstream source was copied or translated. Windows ConPTY, restricted PTY,
durable reconnect, shell integration and complete terminal screen reconstruction
after retention loss remain pending. Real signal tests found both ignored signal
dispositions and blocked masks inherited from the Julia bootstrap; both are reset
before exec. Development Workbench builtin-extension output warnings do not prove
an installed desktop distribution, which remains a separate gate.

## Runtime image and distribution source observations

Checkpoint 030 rereads the handoff's Sysimage/PackageCompiler and standalone
distribution requirements. PackageCompiler 2.4.3 is cloned once and pinned as a
build research dependency. Selected sources below remain a partial review.

| Source | Observation | Independent Julia behavior |
| --- | --- | --- |
| Codex `scripts/build_codex_package.py` 1–65 and `scripts/codex_package/cli.py` 1–35 | Source versions, staging and runtime entry points have separate checks | Core inventories, compiler environment identity, image receipts and detached launch plans have separate contracts |
| OpenCode `script/publish.ts` 1–59 | Distribution coordinates versioned components | The receipt binds Core UUID/version, exact Julia runtime and locked dependencies without adopting upstream publication operations |
| DeepSeek Harness `native/system/scripts/verify-launcher-binary.mjs` 1–63 | Declared native payloads need binary architecture checks | Bounded ELF identity inspection accompanies full image hashing; instruction attestation remains explicitly false |
| Pi `scripts/build-coding-agent-bundle.mjs` 1–57 | Optional runtime dependencies can remain external | PackageCompiler stays outside Core dependencies and its environment uses the existing checkout/depot |
| Kimi Code `apps/kimi-code/scripts/native/check-bundle.mjs` 1–57 | Allowed external dependencies should be intentional | Every Core manifest dependency is compared before the build; no frozen replacement versions are silently accepted |
| ZCode `scripts/zcode-distribution/installer.mjs` 1–55 | Staging and installed-current state differ | Creating a verified experimental image does not establish installation, publication or restored-machine readiness |
| Qwen Code `scripts/installation/install-qwen-standalone.sh` 1–52 | Runtime acquisition and installation paths differ | Sysimage reuse of an existing Julia executable is distinguished from a bundled runtime or standalone application |
| PackageCompiler `docs/src/sysimages.md` 1–78, `apps.md` 1–62 and `src/PackageCompiler.jl` 210–235, 515–544, 678–707, 774–808 | Frozen packages, project inclusion, Julia 1.11 precompile behavior and package-manager globals affect builds | Source/lock fingerprints, isolated compiler environment, disposable workloads and exact runtime validation precede any launch plan |

## Structured compiler evidence source observations

Checkpoint 031 rereads handoff sections 7.11 and 7.44: inferred compiler evidence
can assist diagnosis, but experimental effects do not supply a security boundary.
Selected pinned source reads continue the seven-project review; they do not
establish that every upstream capability has been reviewed or implemented.

| Source | Observation | Independent Julia behavior |
|---|---|---|
| Codex `codex-rs/app-server/src/request_processors/diagnostics.rs` 1–23 | Process diagnostics and named gauges are structured separately | Method/source identity, compiler statistics and execution metadata have distinct records |
| OpenCode `packages/schema/src/lsp-event.ts` 1–7 | Language-service updates use a named event inventory | Owned compiler completion/failure events update the shared UI through existing scoped Core events |
| DeepSeek Harness `packages/lsp/lsp-stdio/src/framing.ts` 1–42 | Byte framing, header limits and message limits are explicit | Existing framed RPC plus bounded helper records and independent strict IR validation protect transport boundaries |
| Pi `packages/coding-agent/src/core/diagnostics.ts` 1–15 | Diagnostic kinds and source/collision evidence are explicit | Advisory compiler findings retain source/statement evidence and never claim observed runtime failures |
| Kimi Code `packages/agent-core-v2/src/app/capability/capabilityService.ts` 1–42 | Scoped capability services distinguish install changes and readiness events | Capability discovery, asynchronous owned inference, result views and cancellation remain separate actions |
| ZCode `packages/shared/src/process-diagnostic.ts` 1–42 | Early errors use a strict bounded stderr side channel | Existing bounded child stderr stays separate from compiler protocol frames; malformed result shapes refuse publication |
| Qwen Code `packages/cli/src/nonInteractive/tool-result-boundary-diagnostics.ts` 1–42 | Per-session result projections retain diagnostic artifacts | Compiler results retain conversation ownership, fingerprints and a pure-body digest independently of the client view |
| Kaimon `src/reflection_tools.jl` 1–44 | Runtime method navigation carries source evidence | Fixed trusted Core target identities use real method locations and source hashes; arbitrary evaluated navigation is outside this contract |
| Julia 1.11.7 `base/compiler/effects.jl` 280–299 | Public predicate helpers distinguish conditional effect encodings | Actual `Base.infer_effects` and compiler predicates retain version-specific encodings and advisory interpretations |

Control blocks, dominators, cycle groups, possible local-slot definitions, SSA
dependencies, validation and UI integration are authored independently. No
upstream implementation is copied or translated. Arbitrary project inference,
complete exceptions/heap effects, runtime evidence and source-graph fusion remain
open. See `docs/core/compiler_ir.md` for precise boundaries.

## Compiler archive source observations

Checkpoint 032 follows the handoff's compiler introspection and experimental
effect-analysis requirements while keeping compiler observations distinct from
runtime measurement. These are source observations from the same pinned seven
primary agent checkouts. The archive implementation is independently authored
Julia; no source is translated or copied. Reviews remain partial across each
project's complete capability surface.

| Pinned source inspected | Observation | Independently implemented consequence |
|---|---|---|
| Codex `codex-rs/history/src/compaction_checkpoint.rs` 1–65 | Recorded producer information remains unknown when absent; malformed latest checkpoints do not grant fallback authority | Unsigned archive digests do not authenticate producers; corrupt selected evidence fails rather than loading an older result |
| OpenCode `packages/core/src/session/history.ts` 1–60 | Ordered history and baseline selection retain decode failures | Catalog revision/digest checks protect ordering and pagination; strict body validation is required when opening evidence |
| DeepSeek Harness `packages/session/session-persistence/src/storage-contract.ts` 1–54 | Shared identity and format checks refuse mismatched session storage | Archive assets and catalogs enforce the same workspace/conversation owner and schema |
| Pi `packages/coding-agent/src/core/session-manager.ts` 159–181, 640–690 | Context edits preserve original records; storage parsing separates validated headers from line-tail repair | Immutable report bodies are retained independently of catalog titles; unsupported/corrupt evidence is exposed without silently repairing it |
| Kimi Code `packages/agent-core-v2/src/persistence/backends/node-fs/atomicDocumentStore.ts` 1–105 | Codec decoding failures and atomic storage writes have explicit boundaries | Bounded decoding and asset/catalog publication have separate checks and error categories |
| ZCode `packages/shared/src/node/privateFilePersistence.ts` 1–68 | Process-local queues and OS locks serialize private file writes; rename retries are bounded | Existing Julia OS locks and atomic replacement serialize revision-checked publication; actual two-process races are tested |
| Qwen Code `packages/core/src/managed-runtime/managed-harness-checkpoint.ts` 1–66 | Awaited approval/runtime work differs from settled completion | RPC archival resolves a completed owned graph job and retains asynchronous approvals/cancellation; a pending save is not a completed archive |

This checkpoint does not implement upstream encrypted checkpoint provenance,
their database/session formats or their managed automation systems. The Julia
archive stores source metadata and compiler reports rather than copying project
directories. Its structural comparison discloses unmatched source anchors and
does not derive performance gains or security isolation from compiler effects.

## Compiler operations and published-state observations

Checkpoint 033 extends independently authored compiler operations with an agent
compile-and-save action, bounded rich-result retention and visible publication
records after interrupted completion. Seven primary source observations inform
the interface boundaries; they do not constitute complete reviews or source
translation.

| Pinned source inspected | Observation | Julia consequence |
|---|---|---|
| Codex `codex-rs/core/src/tools/registry.rs` 195–217 | Tool response content and history truncation metadata are separate | Full bounded compiler evidence/receipts remain distinct from model-facing trimmed tool messages |
| OpenCode `packages/core/src/tool/tool.ts` 1–62 | Tool inputs, structured outputs and model representations have distinct contracts | `compile_archive` executes one Core path for agent and CLI, while original output archival and model previews retain their existing limits |
| DeepSeek Harness `packages/core/tools/src/types.ts` 1–60 | Started/settled nested dispatch events distinguish durable outcomes and structured error identity | Catalog publication is recorded separately from successful owned-job completion; late budget/cancellation errors preserve visible commit evidence |
| Pi `packages/coding-agent/src/modes/interactive/components/tool-execution.ts` 121–160 | Error/partial presentation and bounded expandable output preserve status | The shared UI reports an interrupted operation with recorded publication, rather than describing all stopped work as inference failure |
| Kimi Code `packages/agent-core-v2/src/agent/toolResultTruncation/toolResultTruncationService.ts` 1–82 | Retention, persisted spill pointers and model preview fallback are separate | Diagnostics result limits accommodate bounded archive inventories without changing other managers' defaults or asserting complete model delivery |
| ZCode `packages/ui/src/ToolCallBlocks/toolResultDisplay.ts` 1–44 | Retrieval readiness, task status and truncation have different fields | Owned result byte/depth/node limits and commit evidence have explicit fields rather than one success flag |
| Qwen Code `packages/core/src/core/nonInteractiveToolExecutor.ts` 1–55 | Noninteractive execution reuses the scheduler and distinguishes recording callbacks | Agent/CLI compile-and-save share Core execution; async result delivery and polling apply the same live Read refusal |

Publication records are ephemeral reports by the running Core. They do not
authenticate an external host, provide generic transactional rollback, or make
post-restart replay safe. Historical metadata remains unsigned. The adversarial
long-path inventory validation test is functional evidence, not a performance
benchmark or a claim of efficient large-project indexing.

No upstream source was copied or translated. The artifact receipt is local
integrity evidence, not a signature. Relocation, standalone apps, installed IDE
distribution and clean-machine restore are distinct remaining gates.
