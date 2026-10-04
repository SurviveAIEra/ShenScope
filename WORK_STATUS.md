# Work status

Whole request: IN_PROGRESS. The 250,000-line Core goal is not reached.
Latest cloc 2.11 count: 13,807 authored Julia Core code lines across 123 files;
CLI/TUI add 784 lines and are counted separately. This is 5.5228% of the
minimum line target, leaving 236,193 lines. These are early implementations,
not a mature agent or a complete synthesis of the upstream projects. Reproduce
with `python scripts/core_size.py`; source-size ratios are not feature completion.

Read `docs/requirements/reconstruction.md` for the reconciled requirements.
Prepared: 22 shallow upstream research repositories, Julia 1.11.7 from the
verified official OCI layer, one main checkout. Reference notes are recorded
before application implementation. No copied project directories or worktrees.

Verified checkpoint: five streaming model protocols (OpenAI Chat/Responses,
Anthropic, Gemini, Ollama) using loopback HTTP fixtures; provider-native reasoning
replay; bounded tool arguments; retry before delivery only; hash-guarded edits;
process groups, stdin, retained bounded output and cancellation/timeouts;
bounded parallel tools with exclusive barriers; persistent agent loop, context
projection, headless CLI and configuration profiles/CAS. One deterministic
agent fixture repairs a real failing Python unittest. This uses MockProvider,
not a live model; no live-model or multilingual benchmark claim is made.

`test/runtests.jl`: 119 assertions passed on Linux, Julia 1.11.7, four threads,
2026-10-03. Evidence: `docs/validation/core-checkpoint-001.json`.
Interface checkpoint: versioned framed stdio RPC, scoped approval responses,
asynchronous start/steer/cancel, config CAS and in-memory credential snapshots;
30 protocol assertions and 16 terminal assertions passed. Actual PTY validation
verifies TUI task/approval/Unicode write/exit. Node transport talks to the real
Julia Core and rejects malformed child framing (two passing tests).
Standalone VSIX packages successfully (~62 KiB; authored Core source included,
Julia runtime/dependencies must be installed separately). Native Code-OSS
Workbench/shared-process overlay passes the complete upstream client typecheck
and a real GUI HTTP/tool/approval/file-write test with extensions disabled.
This is a development desktop runtime, not a completed desktop distribution.
Full built-in-extension packaging and Windows installer validation are pending.
MCP integration and isolated compute are verified below; general host-tool OS isolation remains unfinished.
Core remains far below the 250,000-line delivery target.

Storage hardening: atomic replacement now uses OS replacement primitives;
Unix file/directory flushes; bounded journal record reads; shared-ledger checks
under its mutex; finite provider/budget values. Windows 64-bit file flush,
replacement and cross-process lock source is present but not runtime-verified.
Broad Linux suite: 165 assertions passed after shared storage changes; targeted
atomic/bounded-record tests: five passed; finite-config tests add two cases.

Full-project research inventory: `docs/architecture/capability_matrix.md` covers
all 22 pinned checkouts. Rows distinguish research directions from verified
implementations; no complete-synthesis or model-quality claim is made.

Memory checkpoint: workspace/session/user namespaces, provenance/content hashes,
CAS, tombstones, eight-revision histories, expiry, lexical BM25 with Chinese
characters/bigrams and atomic import/export. Nonblocking cross-process locks
fix worker starvation under concurrent writes. Broad affected suite: 204 passing
assertions (32 new memory assertions). `docs/core/memory.md` describes limits.

Next: isolated Julia analyzers and extension lifecycle; durable tasks/MCP;
Julia extensions/diagnostics and isolated analyzers; measured release preparation.

Editor UI checkpoint: compact primary navigation, anchored composer, starter
prompts, safe Markdown/code/file links, grouped tool cards, visible permission
cards, searchable/manageable conversations, structured settings and secure-key
status. Actual native GUI and VSIX Webview flows pass. Full Workbench typecheck
and two Node/Core transport tests pass. V3 Julia-specific requirements have been
rechecked in `docs/architecture/julia_feature_contract.md`; graph work is next.

Project-data checkpoint: stable Core facts/revisions/evidence, resident local
adjacency, checksummed transactional journal, real Go AST, native Tree-sitter
and actual CodeGraphContext/Ladybug backends. Impact/TestSelection/Architecture
are shared ordinary Julia analyzers. Nine 1/5/20-file incremental/full rebuild
oracles agree on a 21-file fixture; 108 integration assertions pass. Protocol
ownership/reload/deny/capacity tests pass. The Project view is connected to Core
jobs and approvals in both editor clients. Detailed limits and commands are in
`docs/core/project_data.md`. Syntax call links remain heuristic; CodeGraph has
global relink/export cost; compiler semantics and cache compaction are verified below; watcher and large-graph
evidence are pending. No Julia performance or live-model quality claim is made.

Julia diagnostics: concrete extension contract reflection, bounded actual
dispatch ambiguity scans, a permissioned invokelatest boundary and separately
executed fixed-target lowered/typed compiler reports. Tests include real missing
methods, deliberate dispatch ambiguity, a World Age failure/latest invocation,
permission denial, IR limits/UTF-8, actual child compilation and timeout.
CLI and the diagnostics tool expose the same implementation. See
`docs/core/julia_diagnostics.md`. This is trusted-Core introspection, not an OS
sandbox for generated analyzers or a completed extension package manager.

Only tested runnable checkpoints will be labeled verified. Update this file
after each checkpoint and push so another machine can resume without chat state.

Compiler semantic checkpoint 013: real TypeScript 5.9.2 checker/language service,
workspace-only source/configuration snapshots, inherited tsconfig paths,
UTF-16/UTF-8 positions, types/signatures, aliases/overloads/implicit constructors,
references/calls/implementations/diagnostics and stable body-edit identities.
The actual 1/5/20-file oracle compares complete file facts, graph and metadata.
An unedited dependent is rechecked after a public signature change. Syntax
failure preserves the committed graph, revision and journal. Semantic checking
is still global; Core persistence and adjacency apply file deltas. No speed
advantage or runtime-call completeness is claimed.

The Project tool, CLI and RPC expose the same bounded snapshot navigation.
Project jobs require owning session IDs for poll/cancel, use child cancellation
with shared budget/policy and cancel pending approvals independently. Process
transport checks argv/executables and handles blocked input, strict JSON,
timeouts, revocation, cancellation and Linux descendant cleanup. All-source,
configuration and commit-permission checks protect publication. Shared Project
UI shows compiler metadata and evidence in both actual clients; the VSIX list,
inspection cards, links and scrollbars have been adjusted and visually checked.

Validation: affected Core 13,340 passing assertions across 95 testsets, including
12,050 coordinate property assertions (1,290 other assertions). Final semantic
suite: 12,252 assertions (202 other assertions); final RPC: 37; CLI/compiler
navigation rerun: 55. Existing nine graph oracles and protocol suite pass (141
assertions before four additional approval-cancel assertions, verified separately).
Editor checks/build, three Node transport tests, complete Workbench typecheck,
native extensions-disabled GUI and standalone VSIX semantic GUI pass. VSIX:
269,348 bytes; 108 Core/manifest/helper payload files match current authored files.
Julia, Node, compiler and depot are still separate dependencies. See
`docs/core/semantic.md`, `docs/validation/semantic-checkpoint-013.json` and raw logs.
Source count, other-language/multi-project semantic support, watching, compaction,
native Problems/Testing/Terminal, isolated analyzers and distribution remain
unfinished. Development continues after this checkpoint.

Durable-task checkpoint: immutable validated DAGs, session/workspace ownership,
checksummed atomic updates, local dependency readiness, leased claims/start/
heartbeat/finish with token+generation fencing, conservative uncertain effects,
explicit reconciliation, safe bounded retries, exclusive effect barriers and
verified dependency result bindings. Tool/test/index/analysis/model dispatch
uses shared policies and budgets; model attempts own separate sessions; workers
exclude recursive task tools. Large results have bounded digest-checked artifacts.
Agent tools, CLI and async RPC use the same Core. Linux broad suite: 359 passing
assertions; final task-focused suite: 114 passing assertions, including actual
two-Julia-process contention and large process outputs. See docs/core/tasks.md
and docs/validation/tasks-checkpoint-008.json. No OS isolation, cross-machine
scheduler, mailbox, editable graph, task-history compaction or GUI Runtime
dashboard is claimed.

Primary-agent priority is explicit in docs/architecture/reference_synthesis.md:
Codex/OpenCode/DeepSeek Harness/Pi/Kimi/ZCode/Qwen remain the main research line.
All reference reviews are marked partial; specialist Hermes/Goose/SDK examples
do not replace the primary projects. Further references named in the history
remain to be evaluated. Next: Skills and Hooks, context recovery and further
primary-agent and Julia-specific Core requirements.

MCP checkpoint: independently authored stdio/Streamable HTTP clients, protocol
negotiation, bounded JSON/SSE framing and catalogs, request/progress/generation
fencing, stable-interval reconnect supervision and conservative no-replay tool
errors. Scoped permissions, environment/secure-storage bindings, local bounded
schema assertions, dynamic remote tool declarations, resources/templates/prompts
and subscriptions integrate with agent, task, CLI and asynchronous Core RPC.
Full affected Core suite: 606 assertions passed; final connection-controls suite:
129 assertions passed. Real VSIX Webview and native Workbench with extensions
disabled pass configuration, approvals, tool/resource/subscription/prompt, ping,
restart, diagnostics and enabled-state flows. Editor transport now verifies
bounded termination of an unresponsive child (three passing Node tests).
Final agent/worker integration adds 52 passing assertions; failed MCP worker calls
emit one completion event and preserve result evidence. Workbench/editor typechecks
pass for the earlier MCP version. The Workbench check preceded the final shared
transport timer edit; the following Skills checkpoint detected and corrects its
type incompatibility. See docs/core/mcp.md and docs/validation/mcp-checkpoint-009.json.
OAuth, server sampling/elicitation, native multimedia projection and real JuliaMCP
interop are pending; Windows descendant cleanup is neither implemented nor
verified. A development desktop runtime is still not a desktop distribution.

Skills checkpoint: project/user SKILL.md catalogs with strict bounded YAML
metadata, source identities and collision precedence; explicit lazy activation
and resources; hash checks after approval and on context reuse; durable session
references, narrowed tool declarations and permissioned one-time source opening.
Agent, CLI and asynchronous RPC share Core ownership. Both actual editor GUIs
verify grouping, activation/approval/deactivation, enable/reload and source files
inside/outside the workspace. Full affected Core suite: 722 passing assertions
(102 Skills assertions); full Workbench/editor checks and three Node transport
tests pass. Six Pi fixtures are accepted and eight rejected; strict compatibility
limits remain documented. See docs/core/skills.md and
docs/validation/skills-checkpoint-010.json. Next: configurable observable Hooks,
context recovery and Julia-specific project/runtime requirements.

Hooks checkpoint: explicit project/user/inline command declarations and eight
lifecycle points; bounded metadata-only stdin and strict output decisions; source/
declaration digests, permission and enabled-state rechecks after approval; bounded
process ownership, cancellation, budgets, private capture and observable results.
Agent, durable workers, CLI and async RPC share Julia Core. Workflow receipts
persist potential Hook effects before launch and enforce exclusive slots/lease
recovery without hidden replay. Both actual editor GUIs verify command tests,
approvals, statuses, source/global enable, reload and configuration opening inside/
outside the workspace. Full affected suite: 885 assertions passed; full Workbench
and editor checks plus three Node transport tests pass. See docs/core/hooks.md
and docs/validation/hooks-checkpoint-011.json. Host OS isolation, durable Hook
audit and complete upstream Hook dialect/event coverage remain unfinished. Next:
context preparation/recovery and project instructions, Julia semantic/project
backends and process/terminal requirements including incremental UTF-8 event
decoding. Continue feature development immediately after the remote checkpoint.

Continuous development is authorized and required: a tested checkpoint is a
commit/push boundary, not permission to stop before the Core target and product
gates. Continue from the next unfinished module without claiming completion.

Context checkpoint: actual provider request accounting, output reservations,
bounded scoped project/user instructions, whole tool-round projections and
immutable original evidence; owned digest-checked checkpoints, explicit optional
structured model summaries, permissioned output artifacts and paged read-back.
Classified context overflow retries only before delivery and only with smaller
requests; interrupted undispatched tools are never replayed. Shared usage and
HTTP I/O deadlines apply. Process event decoding now preserves fragmented UTF-8.
CLI/TUI and both actual editor GUIs expose the same Core. Full affected suite:
1,239 assertions across 89 testsets; final focused suite: 380 assertions; three
Node transport tests and complete editor/Workbench checks pass. Both GUI flows
verify context status, instruction approvals, extractive/model checkpoints,
source evidence and settings. VSIX: 242,075 bytes, 96 Core/manifest payload files
byte-verified. See docs/core/context.md and
docs/validation/context-checkpoint-012.json. Estimates are not exact tokenizers;
model citations do not prove summary prose; no OS isolation, instruction watcher,
history compaction, media slimming or live-model quality is claimed. Next:
compiler-semantic project backend and Julia analysis/runtime requirements.

Project index lifecycle checkpoint 014: streaming replay validates one bounded
frame at a time. Atomic compaction retains complete current facts, metadata and
logical revision. Physical file identity fences stale cross-process writers.
Private owner descriptors allow reclamation of proven-dead Linux staging files;
live/foreign/unclassified files are retained. Recovery requires Persistence.
The tool/CLI/RPC and both editor Project views expose explicit compaction.

Validation: broad affected Core 13,427 assertions / 103 testsets before the final
recovery-permission guard; final focused storage 88 / 8; real TypeScript
compiler/CLI compaction 11; semantic integration 12,262 (including 12,050 position
properties); legacy graph oracles 108; final project RPC 40. Editor build/check,
three Node transport tests, full Workbench check and both actual GUI clients pass.
Raw evidence and source hashes: docs/validation/project-lifecycle-checkpoint-014.json.
No large-graph memory or Windows durability claim. Work continues immediately
with scoped watching, quiet-window change batches and shared editor feedback.

Saved-source monitoring checkpoint 015: owned FileWatching hints plus recursive
content scans, a single-slot wakeup Channel and separate settling timer. Quiet
batches advance their baseline only after committed updates. Identical failed
content waits for a change or explicit retry. Read revocation, denied writes,
shared budget exhaustion and child cancellation retire owned resources. RPC
conversation ownership, manual-mutation reservations and configuration barriers
protect the same index. Compiler inventory digests include excluded inputs.
Both actual editor clients expose observation/automatic mode, pending files,
manual refresh, failure/repair and stop feedback through a shared RPC allowlist.

Validation: final affected Core 13,522 assertions / 110 testsets (12,050 coordinate
properties; 1,472 other assertions); semantic 12,265; watcher/CLI 88; watch RPC 36;
four real-backend/configuration/scope integration 114; fragmented HTTP error
envelopes 12. Editor check/build, three Node transport tests, full Workbench check
and both real GUI flows pass. Raw evidence/source hashes are recorded in
docs/validation/project-watch-checkpoint-015.json. The regression also fixes
complete bounded HTTP error reads when headers/body arrive in separate packets.
No installed-VSIX, Windows, large-project or live-model result is inferred.
Work continues with OS-isolated Julia analyzers, selftests, archival/promotion
and runtime integration. The minimum Core size goal remains unmet.

Isolated analyzer checkpoint 016: actual Linux x86_64 synchronized seccomp with
no-new-privileges, inherited-descriptor closure, descriptor/shared-mapping audit,
CPU/address-space/output/time bounds and owned cleanup. Dynamic code is only
delivered after trusted bootstrap enforcement. Direct open/write/socket/exec/
fork/unlink/rename/mkdir/dup/tracing/cross-process signal calls are denied.
Latest-world reflection and invocation solve Julia dynamic method admission.
External fixtures are compared by Core; self-reported selftest alone is not
validation. Versioned registrations are session scoped, bounded and explicitly
selected. Agent tool and CLI use the same implementation.

Validation: affected Core 13,676 passing assertions across 115 testsets, including
12,050 coordinate property checks and 1,626 other assertions. Final targeted
isolation/registry/external-test suites pass 163 assertions; final shared-map
unit run passes 43 (overlapping) assertions. Three actual editor transport tests
pass. CLI compares two external fixtures and evaluates symbol-kind facts. VSIX
includes byte-identical authored Core/helpers; installed-package and Windows
validation are not claimed. Evidence: isolated-analyzers-checkpoint-016.json.

Next: project-backed dynamic analysis with parent-owned evidence/confidence,
source archives and CAS promotion/rollback, async RPC and both IDE clients.
Continue remaining model/runtime/session/MCP/tool work toward 250,000 Core LOC;
this tested checkpoint is not completion of the whole request.

Graph analyzer checkpoint 017: one isolated Julia analyzer runs on Go AST,
Tree-sitter, real CodeGraph and TypeScript compiler facts. Parent-owned bounded
snapshots bind revision/fingerprint, locations, evidence IDs and provenance;
confidence/connectivity checks reject invented or disconnected evidence. Scores
and reasons remain generated hypotheses about indexed facts. Immutable bounded
project/user JSON archives retain source/tests without Core modification. Scoped
restore never adopts an old receipt as current validation. Fresh external tests
and expected pointer CAS guard promotion/rollback and retained pointer history.
Owned asynchronous RPC and CLI operations share cancellation, permissions and
budgets. Both actual editor clients expose source/fixture review, graph results,
file navigation, archival, two promotions, rollback and pending-approval cancel.

Validation: affected Core 13,926 assertions / 123 testsets (12,050 coordinate
properties; 1,876 other assertions), plus 16 separate CLI assertions; the
standalone four-backend matrix passes 133 overlapping assertions. Editor
check/build, three Node transport tests, full Workbench typecheck and both real
GUI flows pass. VSIX bytes match final authored Core/client sources. Evidence
is in docs/validation/graph-analyzers-checkpoint-017.json, including failed
attempts and the exact loaded-harness distinction. No installed-VSIX, Windows,
live-model quality or large-project performance result is inferred. Archive
automatic pruning and general host-tool isolation remain incomplete. Work
continues with model discovery/counting/routing, runtime worker profiles and
remaining analysis, session, tool and extension capabilities. The minimum Core
size goal remains unmet.
