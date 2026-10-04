# Work status

Whole request: IN_PROGRESS. The 250,000-line Core goal is not reached.
Latest cloc 2.11 count: 20,833 authored Julia Core code lines across 208 files;
CLI/TUI add 1,027 lines and optional Julia extensions add 57, counted separately.
This is 8.3332% of the minimum line target, leaving 229,167 lines. These are early implementations,
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
