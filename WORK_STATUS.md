# Work status

Whole request: IN_PROGRESS. The 250,000-line Core goal is not reached.
Latest verified cloc 2.11 count: 26,623 authored Julia Core code lines across 282 files;
CLI/TUI add 1,360 lines and optional Julia extensions add 57, counted separately.
This is 10.6492% of the minimum line target, leaving 223,377 lines. These are early implementations,
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

Model services checkpoint 018: bounded real model directories for five protocols,
API-declared/unknown capability provenance, conversation/source/credential cache
identity, paged atomic snapshots, TTL and correct single-page ETag validators.
Actual Anthropic/Gemini token-count bodies and explicitly labeled local estimates
share inference request assembly. Count results are not inference usage or
billing receipts. Owned async jobs enforce scope/capacity/cancellation, config
barriers, credential invalidation and nested permission ownership. The same
services are available through tool, CLI, RPC and both actual IDE clients.

Validation: affected Core 14,297 passing assertions; focused
model services 355 assertions overlap that suite. Editor check/build, three
Node/Core transport tests, full Workbench typecheck and actual native/VSIX GUI
flows pass. Final VSIX byte equality is checked against all authored payload
sources/assets. See docs/validation/model-services-checkpoint-018.json and
docs/core/models.md. Failed attempts, the interrupted nested-approval diagnosis
and one native concurrent-start timeout are retained. Catalog persistence,
exact tokenizers, role routing, circuit breakers, live-provider checks and full
desktop distribution remain pending. Development immediately continues with
model request retry/health policy and the remaining agent/project/runtime scope.
The minimum 250,000 Core lines remain an active, unmet delivery constraint.

Model policy checkpoint 019: bounded immutable retry decisions, server wait
floors/veto/cap suppression, exact logical body/key snapshots and no replay after
any output. Cancellation, network revocation and shared deadlines release
inference seats. Scoped bounded circuit state uses epochs, one explicit
half-open probe, neutral non-provider outcomes and CAS reset without network
probing. Agent/task factories and CLI/TUI retain provider runtime health. Both
actual IDE clients show cooldown/reset/verified subsequent fixture recovery.

Validation: affected Core 14,547 passing assertions; focused policy 288 includes
40 prior RPC assertions and overlaps the broad suite. New policy assertions: 248;
new CLI health assertions: two. The broad total includes 12,050 coordinate
property assertions. Editor check/build, three Node/Core transport tests, full
Workbench typecheck and actual native/independent VSIX development GUI pass.
Final package payload equality passes. Failed attempts remain recorded in
docs/validation/model-policy-checkpoint-019.json. Details and boundaries are in
docs/core/model_policy.md. Persistent fleet health, role routing, live-model
checks and installed-package/desktop/Windows validation remain pending.
Development immediately continues with explicit role profiles, eligible routes
and controlled fallback. The 250,000 authored Core-line goal remains unmet.

Model routing checkpoint 020: explicit bounded sources, immutable profiles and
ordered roles; credential-free eligibility planning with actual wire/native
replay checks; captured eligible keys/bodies before approval; typed fallback
before delivery only. Shared fleet circuits, conservative role capacities and
configured-price admission, default/worker factories, scoped receipts and
validated configuration replacement are integrated into CLI/RPC and both IDEs.
Chat roles, service profiles, preview/results and secure keys have shared UI.

Validation: broad affected Core 14,692 assertions, including 145 new routing and
12,050 prior coordinate-property assertions. Final focused routing passes 113,
including four new nested/aliased credential cases after broad source freeze;
RPC passes 64 (40 prior, 24 new), CLI passes 27 (15 prior, 12 new). New routing
assertions total 149; focused/broad overlaps are not added twice. Editor check/
build, three Node/Core transport tests, full Workbench typecheck, final package
payload equality and both actual native/independent VSIX development GUI flows
pass. GUI role selection also proves the worker cannot use the healthy main
backup. Failed attempts and the accessible-name correction remain recorded in
docs/validation/model-routing-checkpoint-020.json. Scope and limitations are in
docs/core/model_routing.md. Durable fleet state, adaptive routing, role imports,
native-history conversion and installed-package/desktop/Windows validation remain
pending. Development continues immediately with evidence-backed Git history,
co-change/risk analysis and the remaining Core/runtime/security scope. The
250,000 authored Core-line goal remains active and unmet.

Git history checkpoint 021: bounded local first-parent snapshots, strict NUL
numstat parsing, full HEAD pin/revalidation, shallow/lookahead/output coverage,
protected/bulk exclusions, exact project-revision joins and commit evidence.
GitCochange and Risk share Julia scoring and bounded result retention across
the Project tool, CLI, conversation-owned RPC jobs and both IDE clients.

Validation: combined focused 135, final Core 96 and affected existing 143
assertions pass; 124 unique new history assertions, overlaps not added twice.
Editor check/build, three real Node/Core transport tests, final full Workbench
typecheck and final VSIX payload equality pass. Both actual native/independent
VSIX development GUI flows verify Go AST indexing, five argv-bound approvals,
exact commit disclosures, co-change/risk metrics and native source opening
without model requests. The final Core reason wording now accurately supports
a custom one-commit minimum; final leaf tests validate that correction.
Evidence and failed attempts: docs/validation/git-history-checkpoint-021.json.
Scope: docs/core/git_history.md. Nested/external Git metadata, rename lineage,
calibrated risk and Windows/installed distribution remain pending. Development
continues with Migration analysis, graph evidence, runtime/security and remaining
requirements. The 250,000 authored Core-line target remains active and unmet.

Migration checkpoint 022: fixed graph/revision/fingerprint proposals, iterative
SCC shared with Architecture, deterministic dependency/caller layers, cycle
groups, strict bounds, relation/test evidence and compatibility review flags.
Depth-boundary omissions now correctly mark ordinary traversal and analyzer
snapshots partial. CPU analysis checkpoints yield to other Julia Tasks.

Validation: focused Core 136 assertions (112 new, 24 prior), affected existing
199, four actual project-data backends, saved-graph CLI/scoped RPC with process/
network/persistence denied, editor check/build, final Workbench typecheck and
final package payload equality pass. Both actual native/independent VSIX GUI
flows validate cycles/evidence, order, partial depth and source opening without
planning-time process/model calls. Concurrent native and Node/Core initialization
exceeded 120-second startup limits; failed logs remain retained. Serial native
and all three Node transport tests pass; serial initialized milestone was
74,567 ms, an observation rather than a controlled performance result.
Evidence: docs/validation/migration-checkpoint-022.json. Proposal limits are in
docs/core/migration.md; plans do not edit, schedule or execute tests. Development
continues immediately with measured boot/precompile work, security/runtime and
remaining requirements. The 250,000 authored Core-line target remains active
and unmet.

Startup checkpoint 023: distinct CLI/RPC compilation boundaries and a disposable
offline PrecompileTools workload capture common metadata/framed-server methods.
Normal package invalidation applies; no terminal, model request or child process
is run during the workload. Source/interface behavior is preserved.

Validation: 805 affected existing assertions eventually pass across all eight service
controllers and relevant CLI/worker paths. Three incomplete test-harness fixture
loads are recorded and corrected without rerunning finished testsets. Two serial
real Node transport suites pass all three tests each. The explicit package-cache
build took 54.956 s; current cache occupies about 39 MiB. Observed cached fresh-
process initialization was 0.338 ms, with module load 1.584 s; cached Node's
initialized milestone was 1.572 s. First agent/tool execution still incurs about
25 s of compilation. These are single observations with different scopes, not
a statistical or installed-desktop benchmark. The final VSIX authored payload
matches. No GUI source or native overlay changed. Evidence and limitations:
docs/validation/startup-checkpoint-023.json and docs/core/startup.md.

Development continues immediately with scoped memory retrieval/management,
security/runtime and remaining requirements. PackageCompiler remains pending.
The 250,000 authored Core-line target remains active and unmet.

Memory checkpoint 024: independent collections with root/session ownership,
strict journal validation, Unicode witnesses/BM25F, filters/phrases/expiry, bounded
partial indexes, fixed-snapshot pagination and declared source/hash evidence.
Julia-owned asynchronous jobs share permissions/budgets with agent work; CLI and
both IDEs support versioned notes and retained history. Seven primary source
observations extend the reference synthesis without copying upstream code.

Validation: 316 distinct affected Core/interface assertions (181 new), three
real Node/Core transport tests, editor check/build, final full Workbench typecheck
and exact VSIX source/assets payload pass. Both actual native and independent
VSIX development GUIs verify approvals, Chinese evidence, updates, namespace
isolation, pagination, deletion and independent durable Julia history checks
without model requests. Failed fixture loads and two GUI attempts are retained
and corrected. Evidence: docs/validation/memory-checkpoint-024.json. Scope:
docs/core/memory.md. Lexical/source evidence is not fact verification; bounded
coverage is disclosed, namespace admission is separate from the fact transaction,
legacy session-proof migration and secure erasure remain pending.

Development continues immediately with general host-tool sandbox/security,
runtime/state and remaining Julia-specific capabilities. The 250,000 authored
Core-line target remains active and unmet.

Execution security checkpoint 025: explicit host/required-Linux policies, bounded
mount plans/protected masks, reduced child state, namespace preflight, Julia-owned
network/resource bootstrap, setup receipts and scoped CLI/RPC/native/VSIX controls.
Read/Edit/Process/Network remain separate; policy/runtime paths are reviewed before
launch, and Deny revocation terminates owned processes. Native signals now report
truthful exit status. Interrupted unsafe durable tasks retain uncertain effects and
receipts, including a real CPU-killed task that first writes a file.

Configuration is validated before replacement; active jobs and draining processes
block saves. Fresh memory/security managers and task references remain usable after
policy changes, preserving durable facts. Seven primary project observations extend
the partial reference review without copying implementations.

Validation: 541 distinct affected assertions (141 new), three real Node/Core tests,
final shared editor check/build, complete Workbench typecheck, exact package payload
and both actual development GUIs pass. Actual kernel network denial, descriptor
closure, CPU/file limits and process revocation pass. This container blocks nested
namespace UID maps and exposes no Landlock interface; target refusal is verified,
while successful full namespaces remain unverified here. Failed API/fixture attempts
and the task cancellation regression are retained with their corrections. Evidence:
docs/validation/security-checkpoint-025.json. Scope: docs/core/execution_security.md.

Development continues immediately with Julia-specific Core capabilities, process
runtime, extensibility and remaining requirements. Domain/platform adapters, full
namespace execution, PackageCompiler and installed restoration remain open. The
250,000 authored Core-line target remains active and unmet.

## Checkpoint 026: Julia source and dispatch evidence

Core: 19,564 authored Julia lines in 190 files; CLI/TUI: 963 lines in 17 files.
The minimum target remains 250,000; 230,436 Core lines are still required.

The JuliaSyntax backend independently extracts modules, types, fields, method
signatures, positional/keyword/default/vararg/where metadata, call expressions
and import/export/include evidence. Stable IDs survive body/line/type-trivia
changes; byte ranges preserve Unicode/CRLF. Project code, macros, generated
functions and includes are not executed. Streaming raw-lexer guards precede
recursive parsing, with explicit source/token/nesting/capacity failures.

Method, conservative dispatch-pattern and structure queries use existing tool,
CLI and RPC contracts. Runtime ambiguity/overwrite/selected-method claims remain
unconfirmed. Both IDEs share source-linked cards and capability declarations.
Independent read/persistence authorization, stale source/revision checks,
cancellation, shared budgets and bounded pages retain the existing semantics.
A disposable query precompile workload fixes a real first-query transport timeout.

Validation: 12,297 distinct affected assertions, including 131 new assertions and
12,050 existing source-position sweep assertions; four real Node/Core tests;
complete Workbench typecheck; shared editor check/build; both actual development
GUIs; and exact VSIX Core/helper/client payload checks pass. Incremental 1/5/20-file
facts and relations match full extraction; replay, compaction and deletion pass.
Evidence: docs/validation/julia-project-checkpoint-026.json. Scope and limits:
docs/core/julia_project_data.md. Failed fixture/API attempts, parser-guard defects
and the deliberately stopped interpreter run are retained with their corrections.

Seven primary agent source observations extend the partial reference inventory;
handoff backend/fusion requirements were reread. The one-checkout constraint and
shared depot remain in effect; approximately 17.6 GiB is free. Package artifacts
are refreshed in place. No project backup/worktree or copied upstream Core exists.

Development continues with the remaining runtime, Julia extensibility, evidence
fusion and distribution requirements. Compiler-confirmed Julia semantics,
cross-backend fusion, PackageCompiler and installed distribution remain open.
The 250,000 authored Core-line target remains active and unmet.

## Checkpoint 027: combined project evidence

Core: 20,173 authored Julia lines in 200 files; CLI/TUI: 988 lines in 17 files.
The minimum target remains 250,000; 229,827 Core lines are still required.

Versioned snapshots combine selected saved backend indexes while preserving
namespaced native identities, provenance, UTF-8 ranges and source hashes. Exact
declaration anchors retain every observation; same-source duplicates disable
bridges, differing hashes refuse capture and extraction differences never select
an automatic winner. Comparison/search and multiple-dispatch impact/test analysis
retain provider/anchor witness steps with explicit heuristic limitations.

Composite reads require one read authorization without launching helpers, writing
indexes, evaluating project code or calling models. Revision/file/configuration
checks, range validation, cancellation, shared budgets and serialized/read/page
bounds protect the operation. This is not a transaction spanning editor writes
and every index. Scope filters and changed-file seeds have distinct meanings.

CLI, owned asynchronous RPC, native Workbench and VSIX use the same implementation.
The shared interface selects indexed sources, displays revisions/signatures and
reachable test evidence, and opens source files. Screenshot review fixes narrow
layout, theme inputs, pending-operation state and a status/start race. Pagination
pins the prior fingerprint and revision vector.

Validation: 279 distinct affected assertions (72 new), five actual Node/Core
transport tests with the normal request deadline restored, both actual development
GUIs, shared editor check/build, complete Workbench typecheck and exact packaged
Core/helper/client comparisons pass. Go AST and Tree-sitter are exercised together
with process/network/persistence denied during saved-fact reads. Evidence:
docs/validation/combined-evidence-checkpoint-027.json. Scope and limitations:
docs/core/combined_evidence.md. Failed ownership/approval fixture assumptions and
concurrent initial-compilation timeouts are retained alongside passing corrections.

Seven primary agent source observations and selected CodeGraphContext/Serena
locations extend the partial capability review. Strict storage audit finds one
application checkout, 46 dependency repositories and no unknown repositories;
about 17.6 GiB is free. There are no project backup copies or worktrees.

Development continues with Julia optional-extension lifecycle, runtime and the
remaining requirements. Git/coverage/runtime fusion, compiler-confirmed Julia
semantics, PackageCompiler and installed restoration remain pending. The 250,000
authored Core-line target remains active and unmet.

## Checkpoint 028: Julia package extension lifecycle

Core: 20,833 authored Julia lines in 208 files; CLI/TUI: 1,027 lines in 18 files.
Optional Julia extension source: 57 lines, excluded from the Core target.
The minimum target remains 250,000; 229,167 Core lines are still required.

Installed independent Julia packages have reviewed identities, compatibility,
entry/Project.toml hashes and explicit dynamic-code authorization. Normal Julia
compilation requests separate process/cache-write grants. Registration is inactive;
activation validates dispatch contracts and freezes tool schemas. Registry UUIDs,
monotonic generations and leases fence old calls. Draining rejects new work,
cleanup callbacks run in reverse order and failures quarantine registrations.
Config replacement/shutdown closes owned registries. These are trusted in-process
packages: arbitrary initialization is not isolated, methods remain loaded and
source inspection does not attest every dependency or compiled instruction.

Tools join actual agent requests through the existing discovery interface. CLI
supports pinned ephemeral invocation; owned async RPC and both IDEs provide
package inspection, scoped approvals, activation, tool parameter forms and results.
A real SparseArrays weak dependency activates an optional sparse evidence
projection with retained relation/anchor provenance and explicit static limits.

Validation: 267 distinct affected assertions (105 new, including the final tool
capability check), six actual Node/Core tests, both actual development GUIs,
shared editor check/build, complete Workbench typecheck and exact VSIX payload
comparison pass. GUI checks cover an independent installed Julia package and
actual optional dependency activation. The final capability-only source amendment
was checked separately and repackaged. Evidence:
docs/validation/extensions-checkpoint-028.json. Scope and limitations:
docs/core/julia_extension_lifecycle.md. Constructor validation, fixture assumptions
and the missing client RPC whitelist found in initial runs are corrected; failed
attempt evidence remains alongside passing results.

Seven primary agent observations and selected PromptingTools/Kaimon sources extend
the partial reference review. Storage audit finds one application checkout,
46 dependency repositories, no unknown repositories and approximately 17.6 GiB
free. One reproducible Core cache pair is retained. No project copies/worktrees
were created. Persistent extension configuration, isolated extension hosts,
provider/backend selection, general process PTY, PackageCompiler and installed
restoration remain pending. Development continues toward all functional gates
and the active 250,000 authored Core-line target.

## Checkpoint 029: owned controlling PTY terminals

Core: 21,477 authored Julia lines in 216 files; CLI/TUI: 1,074 in 19 files.
Optional Julia extension source remains separately counted at 57 lines.
The minimum target remains 250,000; 228,523 Core lines are still required.

Linux PTY handles use an independent Julia bootstrap with a nonce receipt,
controlling-terminal/foreground checks, descriptor closure, parent-death signal,
restored signal dispositions and an unblocked mask before argument-vector exec.
Core owns input, dimensions, foreground interruption, timeout, live process denial,
shared budget and group cleanup. Bounded UTF-8 output retains byte cursors and
explicit loss, independently counts raw bytes and filters control strings across
chunks. Output is ephemeral and stdout/stderr merge. Restricted sandbox PTY and
unsupported platforms refuse execution; host fallback is not inferred.

Agent tools, ephemeral CLI, owned async RPC and both IDEs use the same runtime.
Native Workbench attaches a custom child-process adapter through its terminal
service; VSIX attaches a pseudoterminal. Neither client starts a shell. Actual
terminal widgets exercise scoped approvals, Chinese/emoji typing, dimensions,
output pages, interruption and removal. Competing per-conversation mutations
retain the existing busy refusal. Native attachment requires read Allow.

Validation: 296 distinct affected assertions (71 new), seven actual Node/Core
transport tests, both actual development GUIs, shared editor check/build, complete
Workbench typecheck and exact VSIX payload comparisons pass. Source amendments
for idempotent cleanup and contract discovery were checked separately and current
GUI/Node flows rerun. Evidence: docs/validation/terminal-checkpoint-029.json.
Scope/limits: docs/core/terminal_runtime.md. Initial worker syntax failure,
inherited signal-mask defects, fixture API assumptions and source-invalidation
compilation timeout remain recorded with their corrected runs. Development
Workbench builtin-extension build warnings remain visible; installed desktop
packaging is not claimed.

Seven primary-agent source observations and the handoff/native IDE guidance extend
the partial reference review. Storage retains one application checkout and shared
depot; 46 dependency repositories and no unknown checkouts were audited. About
17.5 GiB is free and known reproducible build artifacts are refreshed in place.
No project directories or worktrees were copied. Windows ConPTY, restricted PTY,
durable reconnect, shell integration, detached hostile-process containment,
PackageCompiler and installed restoration remain pending. Development continues
through the remaining functional gates and the active 250,000 Core-line target.

## Checkpoint 030: runtime image integrity and actual PackageCompiler build

Core: 21,790 authored Julia lines in 221 files; CLI/TUI: 1,102 in 20 files.
Optional authored Julia extension source remains separately counted at 57 lines.
The active minimum remains 250,000; 228,210 Core lines are still required.

Sorted bounded source/dependency inventories and strict image receipts bind
Core UUID/version, preferences, exact Julia/platform, generic CPU target, compiler
environment and streamed image hash. Separate read, persistence and dynamic
permissions govern inspection, publication and detached launch planning. Unknown
fields, duplicate JSON keys, stale sources/locks, changed bytes, unsupported
platforms and descendant symlinks refuse validation. A receipt is unsigned;
ELF architecture checks do not attest compiled instructions and planning is not
an atomic file-to-exec operation. Runtime/status reports loaded-image metadata
without treating environment markers as provenance.

PackageCompiler 2.4.3 was cloned once and developed with the existing Core into
a separate small build environment. Every Core manifest dependency was compared
before building. One real incremental generic Linux image took 495.728 seconds
and produced 311,352,856 bytes with matching pre/post source fingerprints. The
image passed 120 distinct affected assertions (27 new), seven real editor/Core
transport tests, independent package/weakdep extension behavior and all five
local HTTP model protocols. The refreshed VSIX exactly matches 250 authored
Core/helper/extension payload files and three existing client assets. Actual GUI
flows were unchanged and were not rerun for this checkpoint.

Three serial alternating fresh-process metadata observations measured median
wall time of 2.128 seconds with the ordinary package cache and 0.708 seconds
with the image. This establishes neither full IDE latency nor live-provider,
first-agent-turn, relocation, Windows, installed distribution or clean-machine
restore performance. Editor launch defaults remain ordinary Julia. Reproduction,
limits and evidence: docs/core/runtime_images.md and
docs/validation/sysimage-checkpoint-030.json.

Initial workload constructor/path mistakes and restricted-sandbox child/loopback
failures are retained with corrected successful runs. Supported permission
escalation verified GitHub access and actual Node/HTTP tests. Seven primary-agent
sources and Julia handoff/compiler requirements extend the partial reference
review; no upstream code was copied or translated. After verification the single
experimental binary and known reproducible compiler artifacts were removed,
reclaiming 423,664,125 bytes. About 17.5 GiB remains free. The strict audit found
one application checkout, 50 dependency repositories and no unknown repositories;
no worktrees or application-directory copies were created. Development continues
through the remaining gates and the active 250,000 Core-line target.

## Checkpoint 031: structured Julia compiler evidence and owned IDE inference

Core: 22,793 authored Julia lines in 230 files; CLI/TUI: 1,108 in 20 files.
Optional authored Julia extension source remains separately counted at 57 lines.
The active minimum remains 250,000; 227,207 Core lines are still required.

Real unoptimized inferred CodeInfo for six fixed trusted Core targets now yields
bounded source/method/type/operand records, explicit normal control blocks,
reachability/dominators/cycle groups, possible local-slot definitions, SSA uses,
call projections and advisory findings. Anonymous and duplicate slot names keep
distinct IDs. Actual Base.infer_effects predicates disclose experimental,
version-specific guarantees without claiming security or measured performance.
The parent checks source/runtime/body pins and independently recomputes graph
projections before publication. Arbitrary project code is not loaded or executed;
exception edges, heap aliases and executed dispatch remain outside this report.

Owned diagnostics RPC jobs separate metadata from permissioned inference. Live
read/dynamic denial, shared budgets, pending-approval cancellation, conversation
ownership, busy/config guards, bounded retention and shutdown cleanup apply.
The host helper refuses configured restricted sandboxes. CLI, agent tool, native
Workbench and VSIX share Core behavior. The Runtime UI presents method metrics,
forty-row statement pages, uncertainty/block filters and effect qualifiers.
Narrow-sidebar type names, pagination and theme dropdowns were inspected and
corrected through actual screenshots and GUI runs.

Validation includes 73 new assertions and 246 distinct affected Julia assertions,
eight actual Node/Core transport tests, actual separate compiler children and
CLI graph output, native Workbench with extensions disabled and independent VSIX
interaction. TypeScript/shared builds and the complete Workbench client typecheck
pass. Exact package checks cover 259 authored Core/helper/extension/metadata files
and three client assets in the refreshed VSIX. Installed/relocated packages,
Windows and remote CI results are not implied by these local observations.

Real IR tests exposed anonymous/repeated-slot assumptions and a JSON empty-set
element-type bug; both were corrected. Initial Node assertion field mistakes,
sandbox spawn refusal, interrupted GUI execution and an Xvfb zombie lock were
retained as failed evidence. The GUI harness now awaits an automatically allocated
ready display. Missing standalone parser-test helpers were factored into a shared
fixture and a reproducible focused compiler suite. Editor tests honor configured
Julia/depot paths; CI supplies its runner paths. A concurrent final transport run
also exposed first-request compilation exceeding the old thirty-second job-start
timeout. Shared clients now allow 120 seconds for owned job admission; normal
requests and explicit caller timeouts retain their limits. Evidence:
docs/validation/compiler-ir-checkpoint-031.json and docs/core/compiler_ir.md.

The seven primary agent sources and Julia compiler/effect handoff requirements
extend the partial reference review; no upstream implementation was copied or
translated. One application checkout, 50 dependency repositories and no unknown
repositories passed the strict audit. The shared depot retains only the current
Core cache pair; no experimental sysimage or project copy was created. About
17.5 GiB is free. Development continues with compiler evidence retention,
comparison/fusion, runtime/state and remaining functional gates alongside the
active 250,000 authored Core-line target.

Compiler archive checkpoint 032: bounded workspace/conversation-owned immutable
report assets, a revision-checked atomic catalog, stable pagination, rename,
explicit removal and verified orphan cleanup. Source inventories store metadata,
not source copies. Historical validation accepts recorded source hashes/line
numbers and recomputes graph projections without loading historical code. It
retains the current fixed-target signature compatibility contract. Unsigned
digests do not authenticate producers; opened reports explicitly leave current
source agreement unchecked. Missing/corrupt selected evidence refuses access.

Comparison requires the same target, arguments, Julia version and platform;
unique source/opcode/kind anchors pair statements while ambiguous/unknown anchors
remain unpaired. Return types, structural counts, callee classes, uncertain values
and experimental effects are reported without performance or equivalence claims.
All operations retain live permission, budget/cancellation and capacity guards.
Save rechecks source immediately before catalog publication. Staging bytes and
orphans count against save capacity; cleanup only removes validated unreferenced
assets and does not recursively remove folders.

CLI compile-and-save requires an existing conversation and expected revision;
RPC saves resolve owned completed graph jobs. Both editor clients share report
titles, catalog/open/rename/remove, comparison and explicit cleanup. Recorded
report labels distinguish historical evidence; conversation/configuration changes
clear view state. Permissioned catalog refreshes retain an explicit snapshot.
Actual screenshots exposed theme inheritance for comparison dropdowns, which was
corrected. Ephemeral operation-result capacity remains an independent limit.

Validation: 218 affected Julia assertions including 81 new archive/CLI assertions,
actual compiler children, previous-source evidence, two competing real Julia
processes and cancellation before catalog publication. Real Node/Core transport
passes Read/Persistence approvals, foreign ownership refusal, stale-write errors,
cancelled saves and cleanup. Both actual GUI clients pass two-report workflows,
historical disclosure and manual-refresh cleanup; complete Workbench/client type
checks pass. Final package/source verification and screenshots are recorded in
docs/validation/compiler-archive-checkpoint-032.json. The initial excessive JSON
encoder depth configuration failed and was corrected; its raw failure is retained.

Primary observations extend all seven agent reviews with recorded producer,
identity/version validation, atomic storage, locking and settled-job boundaries.
No upstream source is copied or translated. One app checkout, 50 dependencies and
no unknown repositories remain; about 17.5 GiB is free, with one current Core
cache pair and no new sysimage or full-directory backup. Core increased by 660
authored lines. Agent-driven compile-and-save, project inference, graph fusion,
remaining runtime/state capabilities and the 250,000-line target remain active.

Compiler operation checkpoint 033: the normal agent diagnostics tool can compile
and save a graph report with an expected catalog revision. CLI compile-and-save
uses the same implementation. Invalid modes, irrelevant parameters, persistence
denial and an already-stale revision refuse before inference; a concurrent writer
may still cause a final CAS conflict. The compiler target table remains fixed.

Owned diagnostics explicitly retain up to 3 MiB plus wrapper overhead, with
bounded depth/node counts and 8 MiB aggregate retention. Other operation managers
keep their existing default bounds. A synthetic unsigned long-path source
inventory exercises a real stored report and framed read larger than the former
result cap, without making source copies or claiming large-project performance.

Publication events record bounded workspace/conversation receipts before client
notification. A sink failure after atomic publication does not undo storage or
report the mutation as uncommitted. A cancellation or budget failure after that
point retains the receipt while reporting the operation's actual terminal state.
These are ephemeral unsigned Core reports, not external attestation, durable
generic side-effect receipts or automatic rollback. Live Read denial before
delivery fails the operation and filters results/receipts from both polling and
notifications. The editor tells users to refresh after a recorded publication.

Validation: 261 compiler/operation assertions and 36 distinct shared protocol
assertions pass, including 43 new assertions. Real Node/Core transport checks
publication receipts and conflict refusal. Native Workbench and standalone VSIX
actual GUI regressions, shared checks/build and full Workbench typecheck pass.
The initial missing initialize in a new fixture and the late-Read-denial failure
are retained with the successful regression in
docs/validation/compiler-operations-checkpoint-033.json. The actual agent fixture
uses MockProvider; live-model quality is not claimed.

Source observations extend all seven primary agent reviews. No upstream source
is copied or translated. The strict audit still finds one application repository,
50 dependencies and no unknown repositories. About 17.5 GiB is free, with no new
project copies, worktrees or sysimages. Core increased by 78 authored lines;
compiler source navigation, project inference, graph fusion and the remaining
product/size gates continue.

Compiler source checkpoint 034: graph inference explicitly retains actual Julia
source debug information. The supported runtime's display default had dropped
all statement codelocs; the real six-target reflection probe confirms the cause.
The cliptext graph now preserves 63 of 65 positions. Missing positions remain
unknown. Source coordinates have no column precision or executed-path claim.

An owned completed graph job or a cataloged historical report can request a
method/statement source preview. Read/ownership guards, strict source membership,
UTF-8/byte bounds, file SHA-256 and line range checks run before publication.
No arbitrary filename is accepted. Current jobs require complete inventory
agreement; historical previews verify the selected installed file and explicitly
leave the full inventory and unsigned producer unverified. Symlinks, changed
bytes, external/missing positions and out-of-file lines refuse the read. Lazy
line iteration retains only the chosen window, with explicit long-line omissions.

Both IDE clients share compact line buttons, declaration previews, highlighted
line numbers, hash/currentness context and explicit close. Source state resets
with report/configuration/conversation changes. Unique authored Core anchors
now pair actual statements; repeated/unknown/zero positions and external
basenames remain unpaired. Comparison exposes source availability separately
from structural changes and makes no performance/equivalence claim.

Validation: 308 affected Julia assertions, including 47 new source/CLI assertions,
actual compiler helpers, current/historical reads and scoped approvals. Real
Node/Core transport and both actual GUI clients pass source previews, ownership,
unique/ambiguous pairing and archive regressions. Shared checks/build and complete
Workbench typecheck pass. A new fixture's incorrect constructor keyword was
fixed. Actual screenshot inspection exposed long-line sidebar overflow; bounded
grid/flex sizing and actual width assertions now pass in both clients. Raw
failed/passing evidence and inspected screenshots are preserved in
docs/validation/compiler-source-checkpoint-034.json.

All seven primary agent reviews extend with bounded read and source-display
observations; no source is copied or translated. The strict audit still finds
one app checkout, 50 dependency repositories and no unknown repositories, with
about 17.5 GiB free. No project copies, worktrees or sysimages were created.
Core increased by 114 authored lines. Actual Profile.Allocs/measurement probes
for three trusted targets are preliminary research; the public profiling service,
arbitrary project inference, combined compiler/project facts and remaining size/
functional gates continue.

Runtime measurement checkpoint 035: three fixed nonmutating Core targets now
execute deterministic typed workloads in a one-thread Julia helper. Warmup is
separate from repeated actual @timed batches, and Profile.Allocs uses a separate
sampling pass. Output hashes/checksums agree across all passes. Bounded retained
allocation samples expose only authored Core frames with source hashes; timing
and allocation aggregates are independently recomputed by the parent. Sampled
bytes can differ from timed bytes, even at rate one. Driver overhead, remaining
compilation, scheduler noise and helper background activity remain visible limits.

The agent diagnostics tool, CLI, owned RPC and both editor clients share this
implementation. Fixed fixture selection accepts no user code or project loading.
Read, Dynamic and Process approvals, current source inventory, cancellation,
timeout and live revocation use the existing trusted-host execution boundary.
Configured restricted sandboxes refuse this execution. Runtime cards retain a
previous IR view and show timings, sampled types, first Core frames and explicit
measurement scope. They make no CPU, RSS, heap-retention or optimization claim.

Validation: 391 distinct affected Julia assertions pass, including 83 new
profiling assertions, actual helper execution, source/payload forgery refusal,
empty sampled output with nonzero timing allocations, permission revocation,
timeout, real MockProvider agent use and CLI use. Two distinct Node/Core tests
pass across their recorded runs. The first combined Node run retained a failing
test expectation for configuration-driven operation retirement; the corrected
profiling test passes. Both actual GUI clients and shared/full Workbench checks
pass. Evidence is in docs/validation/compiler-profile-checkpoint-035.json.

Seven primary source reviews inform original timing/measurement scope and
visible usage design; no upstream code is copied or translated. The strict
repository audit still finds one application checkout, 50 dependencies and no
unknown repositories. About 17.5 GiB is free, with one Core cache pair and no
project copies, worktrees or new sysimages. Core increased by 397 authored lines.
Project/compiler/runtime fact fusion and remaining product and size gates
continue; arbitrary project profiling and broader performance evidence are pending.

Runtime evidence checkpoint 036: owned completed compiler/profile jobs join fresh
JuliaSyntax declarations from hash-verified installed Core files. The join uses
canonical FileFacts/CodeSymbol independently of CodeGraph private schemas.
Reports require identical target/signature and current complete source inventory.
No project loading, target execution or persistent indexing occurs during reads.
CLI/agent inspect explicitly runs two fixed helpers first, then associates facts.

An interval index with prefix maximum end lines retains all containing callable
declarations. Witnesses retain report/observation/declaration identities, hashes
and ranges. Multiple candidates stay ambiguous and unknown positions unmatched.
Candidate overflow and out-of-file coordinates refuse. Even unique matches do
not prove runtime bindings or semantic equivalence. Allocation frame rows are
not additive; original timing and retained-prefix totals remain separate.

Read/ownership/currentness, cancellation/shared budget and file/byte/declaration/
observation/join-work/page bounds remain enforced. Invalid inspection parameters
refuse before helper execution. Evidence digests pin pages and source previews.
The current adapter reparses selected installed Core files without a hidden cache.
Additional providers, arbitrary project compiler/runtime/coverage fusion and
large-project evidence remain pending.

Both clients share association, category/filter/page controls, candidate details
and allocation source previews. Runtime shows metadata loading immediately.
Actual narrow-sidebar overflow prompted bounded grid/select/input sizing and
responsive navigation. Screenshots capture the scrolling panel rather than a
tall clipped element.

Validation: 146 final evidence/owned assertions and 308 affected compiler/archive/
source assertions pass. Excluding 30 repeated owned assertions gives 424 distinct
affected assertions including 116 new ones. Compiler regression preceded final
evidence-only preflight/range guards; its source-preview implementation is
unchanged and final evidence tests cover those new guards. Two distinct real
Node/Core tests pass in recorded runs. Corrected fixtures use the internal
namespace, actual CLI entry, sessions/create, job_id and exact unknown-field
rejection. Native/VSIX actual workflows, shared checks/build and complete
Workbench typecheck pass. Failures/screenshots are retained in
docs/validation/runtime-evidence-checkpoint-036.json. MockProvider is explicit;
no live-model, performance, Windows or distribution claim is made.

Seven further primary source reviews inform original identity/provenance and
adapter boundaries. No source is copied or translated. Strict audit still finds
one application checkout, 50 dependencies and no unknown repositories. About
17.5 GiB is free with one current Core cache pair and no project copies, worktrees
or new sysimages. Core increased by 410 authored lines. CPU sampling, remaining
runtime/state/model capabilities and all remaining size/functional gates continue;
the 250,000-line target remains far from reached.

Periodic sampling checkpoint 037: actual Julia Profile periodic backtraces run
three fixed Core fixtures in one-thread trusted helpers. Warmup, requested loop
window and instrumented elapsed remain separate. Finite buffers retain only a
bounded prefix; sample/frame/stack/inline-lookup truncation is explicit. Parent
validation recomputes unique source-frame occurrences and inclusive fractions.
Task/instruction identities and external paths are omitted. Fractions are not
CPU utilization or exclusive target time, and empty samples do not prove no work.

Owned sampling reports can join compiler and allocation reports with the same
current target/signature/source inventory. Evidence reads do not execute targets.
Sampling observations preserve sample/frame handles, independent provenance and
hash-verified source previews. Declarations remain candidates. The ordinary
agent tool, CLI, scoped RPC, VSIX and native Workbench share these contracts.

Validation: 138 sampling/owned assertions, 308 compiler regressions, 109 profile
regressions and 146 evidence regressions pass. Excluding 86 repeated assertions
leaves 615 distinct affected assertions, including 108 new ones. Three real
Node/Core tests pass, with the final sampling test additionally rerun after its
failure-event wait was improved. Both complete compiler GUI workflows pass.
Visual inspection then found a squeezed narrow source heading and panel
pagination overflow: final focused native/VSIX workflows verify readable source
headings, no panel horizontal overflow and actual sidebar sash resizing for wide
screenshots. Shared checks/build, full Workbench typecheck and exact VSIX source
payload checks pass. Raw logs and the initial structurally-valid sample-count
fixture failure are preserved in docs/validation/compiler-sampling-checkpoint-037.json.
No live-model, comparative speed, Windows or installed-distribution claim is made.

Seven further primary source reviews preserve collection/unit/scope distinctions;
no upstream implementation is copied or translated. Strict audit still finds one
application checkout, 50 dependencies and no unknown repositories. About 17.5 GiB
remains free, with one Core cache pair and no project copies, worktrees or new
sysimages. Core increased by 310 authored lines. Remaining agent modes/planning,
context/state/model/project/runtime/distribution capabilities and the 250,000-line
functional and size gates continue. The task remains IN_PROGRESS.

General planning checkpoint 038: explicit user-controlled Plan/Act settings and
bounded conversation plans share the existing session journal. Julia ScopedValue
preserves Plan across Task/Threads/new contexts and nested Act scopes cannot
relax it. Reviewed Core types/actions narrow model declarations; direct dispatch
and permissions enforce the same operation boundary. Act never grants permission.
Plan forbids workspace edits, commands, dynamic code, MCP and unreviewed plugins;
own plan/context state keeps independent Read/Persistence checks.

Actual nonblocking OS run locks fence the entire agent turn and mode update.
Cross-process attempts refuse, kernel locks release after a killed process, and
stale journal revisions refuse. Plans contain bounded named steps/dependencies,
CAS revisions, hashes and owned message citations. Cycles, premature dependent
progress, corruption and missing completion citations refuse. Reported progress
does not prove execution/testing and does not automatically schedule work.
Full branches retain progress; partial branches reset it and remove later
citations. Both retain mode with independent child ownership/ancestry. History
streams a bounded journal window without creating version directories or copies.

CLI chat selection, session mode/query, plan reads/writes and asynchronous TUI
/mode and /plan controls are connected. Both GUI clients share the composer
mode selector and reported-plan review, history restore and new-session isolation.
Actual screenshots prompted theme-aware selector colors and a shorter narrow
review explanation. Final native/VSIX layouts measure 197-pixel narrow and
357-pixel wide content without horizontal overflow, using real sidebar resizing.

Validation: 161 final plan/mode assertions, 11 actual cross-process/crash assertions
and 778 affected Act workflow assertions pass, totaling 950 distinct assertions,
including 172 new ones. The Act regressions preceded the final AbstractString
mode parser fix; shared agent/journal/tools were unchanged afterward, and final
plan tests plus actual clients cover that fix. Real Node/Core restart/permission
test, actual PTY Plan/Act/approval flow, both actual GUI workflows, shared checks/
build, complete Workbench typecheck and exact final VSIX payload checks pass.
Parser, terminal-approval fixture and editor allowlist failures are preserved in
docs/validation/agent-plans-checkpoint-038.json with raw outputs/screenshots.
No live-model, Windows or installed-distribution quality claim is made.

The tool is general across target-project languages; Julia implements Core.
Real agent fixtures read Python, JavaScript and Rust sources without modification
in Plan and perform actual approved writes in Act. This does not establish
complete language intelligence or repair quality. After this checkpoint prioritize
general project testing/failure navigation and additional language coverage over
further fixed-Core compiler diagnostics. Eight further source observations across
all seven primary agents inform original design, without copying or translation.

Strict audit still finds one application checkout, 50 dependencies and no unknown
repositories. About 17.5 GiB remains free with one Core cache pair and no project
copies, worktrees or new sysimages. Core increased by 569 authored lines. General
project workflows, remaining product gates and the 250,000-line goal continue;
the whole request remains IN_PROGRESS.

General project testing checkpoint 039: bounded read-only marker discovery,
owned catalogs, selected-marker revalidation after approval and any-language
argument-vector execution. Exit/signal/timeout/cancel/revocation evidence is
separate from framework-reported cases, counts and untrusted file references.
Current source previews use ordinary Read policy and an expected content hash;
no execution source snapshot or complete test coverage is inferred. Zero-exit
framework failures remain failed tool and after-test Hook outcomes. Read denial
also filters retained RPC results and outgoing testing notifications.

Actual failing-test/hash-edit/rerun fixtures pass for Python, JavaScript, Go, C
and C++, using MockProvider and real runners/compilers. No live-model quality
claim is made. New targeted suite: 155 assertions in nine testsets. Affected
agent/tool/storage/RPC/provider/Hook/task/CLI suite: 778 in 65 testsets (933
distinct passing assertions). Node/Core, real PTY TUI, native extensions-disabled
GUI and VSIX development Webview tests pass. Both layouts are 197/197 px narrow
and 357/357 px wide with no horizontal overflow; final screenshots were viewed.
Full Workbench and shared client typechecks pass.

The final VSIX has 317 entries; 308 Core/helper/extension/metadata files and all
three client assets match source (655,470 bytes, SHA-256
`ee6db8b30223490a8cdde76ea7c86d4a0f659657bce08f7391f194c81e3386a0`).
Package installation and a finished desktop distribution are not verified.
Controller receipts are bounded in memory and do not survive Core restart;
normal agent results remain in conversation journals. Native Testing API,
durable controller history, coverage and more frameworks are pending.

Evidence and retained failures: `docs/validation/project-testing-checkpoint-039.json`.
Research adds seven pinned source observations across all primary projects,
with original Julia implementation and no copying/translation. Strict audit
still finds one application checkout, 50 dependencies and no unknown repositories.
17.466 GiB remains free; one Core cache pair is reused, with no whole-project
copies, worktrees or sysimages. Core increased by 913 authored lines. Continue
general project workflows and the remaining functional/250,000-line gates.

## Checkpoint 040: explicitly saved project test results

Owned test receipts can now be saved, read after Core restart, renamed or deleted
without launching their commands. One atomic snapshot per workspace/conversation
holds at most 32 records, 4 MiB per receipt and 16 MiB serialized total. Saving
requires independent Read/Persistence permissions and expected revisions; no
automatic retirement, project-folder copies or per-revision backup trees.
Cross-process locks and final digest checks fence stale writes. Normal staging
is removed; only identified dead Core stages older than one hour can be reclaimed.

Publication evidence survives later notification failure or cancelled job
completion. Current Read denial hides both result bodies and commit receipts.
Read-only Plan mode exposes saved-history queries but cannot write them. Source
previews verify current workspace files independently of the historic result;
saved output is not proof of whole-project coverage or a historic source snapshot.

90 new Core assertions across eight testsets pass, including real two-Julia-
process contention, ownership, corrupt data, capacity, permissions, CLI failures,
current-source hashes and post-publication cancellation. Project-testing
regression adds 155 assertions and shared operation/commit regression adds 54;
299 assertions across 23 testsets pass. Two real Node/Core tests pass, including
a Core process restart and a counter confirming the saved command executed once.
Both actual clients pass independent process/persistence approval, saving/naming/
reopening/deleting results, current source previews and actual editor file opening.
Layouts fit 197/357 px without horizontal panel overflow; shared/full Workbench
typechecks and client builds pass. Initial sandbox/typecheck failures and one
native GUI timeout are retained; the final standalone GUI runs both pass.

The VSIX has 322 entries; 313 Core/helper/extension/metadata files and all three
assets match authored source. It is 665,849 bytes, SHA-256
`97a0ff5754c544fb12e91acc47f700d7c80f4cca4be56edd7ffec66082809d4c`.
Development VSIX execution is verified; package installation and a complete
desktop distribution are not. Native Testing API integration, broader reporting
formats/coverage and the other product gates remain unfinished.

Seven further pinned partial primary-agent reviews are recorded. Strict audit
still finds one application checkout, 50 dependencies and no unknown repositories.
One reusable 60,566,800-byte Core cache library and its 1,720,095-byte metadata
file remain; no new sysimage or directory duplication. Core adds 379 authored
lines, now 26,623. Evidence: `docs/validation/project-test-history-checkpoint-040.json`.
Continue native Testing integration and the functional/250,000-line gates.
