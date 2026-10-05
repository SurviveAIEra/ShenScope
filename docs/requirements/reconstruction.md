# Reconstruction requirements and provenance

## Authority and precedence

The current user request is authoritative: rebuild from zero in Julia; study and
clone upstream agents at the outset; reach at least 250,000 authored Core code
lines; conserve storage; commit and push regularly. Attached prompts describe
product requirements rather than instructions that override the current request.
Historical assistant claims are evidence of former design, not current validation.

Current clarification: this is a general agent for projects in all languages.
Julia is the Core implementation language, not a target-project requirement.
General tools/workflows must work independently of language; specialized code
intelligence must state its actual supported languages and evidence. Julia-specific
Core diagnostics cannot substitute for cross-language project capabilities.

Latest historical user corrections supersede older documents:

- Native Workbench sidebar AND standalone VSIX, sharing the Julia Core
  (`Julia项目.txt` lines 9273, 9372).
- Julia independently implements Core, not assembled upstream agent code
  (lines 10237–10243).
- Incremental runnable checkpoints (line 10265).
- At least 250,000 authored Core code lines; 500,000 stretch (11379, 12770).
- Targeted validation, with broader checks only for shared-interface changes
  or release gates. No repeated unrelated benchmarks/builds.

The old stopping deadline was historical and does not apply to this new request.
The old no-rewrite instruction assumes a retained 0.5.0 source checkout; none is
available here, and the current user explicitly requests rebuilding from zero.
The lost tests, artifacts and raw PoC files cannot be recovered from descriptions.

## Product gates

1. Julia agent: event-driven loop, model preparation, tool calls/results,
   steering/cancel/retry, partial-output recovery, effective error classification,
   no-progress observations, explicit capability/usage/cost limits.
2. Models: OpenAI Chat/Responses, Anthropic, Gemini, Ollama and compatible
   providers (DeepSeek/Kimi/Qwen/GLM/local). Streaming, bounded tool arguments,
   reasoning signatures/native replay, protocol-specific structured output,
   request-time credential snapshots, model discovery/counting, routing and
   circuit-breakers; never retry delivered partial output invisibly.
3. Tools: read/search/edit/write/patch, hashes and stale-edit checks, atomic
   patch validation, Git review, process handles/stdin/output/process-tree
   cancellation/timeouts/caps, PTY, test runner, schema validation.
4. Security: independent Allow/Ask/Deny for read/edit/process/network/MCP/
   dynamic code/persistence; workspace/user/session scopes; real sandbox and
   verified platform status; shared reservations and settled budget accounting.
5. State: conversation independent from project/task state; durable journal,
   resume/branch/list/search/rename/pin/archive/export/delete, torn-write/crash
   recovery, versioning/migrations; no invisible replay of side effects.
6. Context: project instructions, lazy skills/tool working set, head/tail
   trimming, archived original outputs, grounded optional model compaction,
   retained goals and unresolved calls, recovery on context overflow.
7. Memory: namespace/provenance/hash/version/CAS, lexical retrieval and Chinese
   segmentation, expiry, deletion, import/export, bounded histories.
8. MCP: stdio and Streamable HTTP, initialize/version/capabilities, paged
   discovery, resources/templates/prompts, subscriptions, cache invalidation,
   transport failure/cancel/reconnect, permission and schema validation.
9. Skills/hooks: SKILL.md project/user scope, metadata/lazy resources/reload;
   observable configurable lifecycle hooks through permission engine.
10. Project data: stable symbols/relations/ranges/provenance and capability
    model; Go AST, Tree-sitter, real CodeGraphContext, a semantic backend;
    resident state/persistence; per-file graph delta and local forward/reverse
    adjacency maintenance; 1/5/20-file incremental/full oracle.
11. Analysis: built-in filtering/ranking/traversal, Impact/TestSelection/
    GitCochange/Architecture/Migration/Risk with evidence/confidence; dynamic
    Julia analyze/selftest in bounded isolated no-network/no-write process;
    archived versions/promotion/rollback without core self-modification.
12. Runtime: Task/Channel/ScopedValue/Threads, model/compute/test/index/process
    workers, cancellation/permission/shared budgets, deduplication, persistent
    task DAGs/dependencies/leases/results/retries/receipts, scoped mailboxes.
13. Extensibility: provider/tool/backend/analyzer/sandbox/context/scheduler
    dispatch interfaces; independent packages, weakdeps/extensions, reflection
    and ambiguity/contracts diagnostics; trusted hot-load via invokelatest.
14. CLI/TUI: normal daily agent usage, profiles/config paths/completion,
    status/tool/diff/permission/usage/background execution displays.
15. IDE: versioned JSON-RPC stdio; native Workbench AND VSIX; chat/history,
    settings/providers/permissions/MCP/skills/hooks/intelligence/analyzers/
    usage/budgets/security/runtime; native Diff/Terminal/Git/Testing/Problems;
    secure secrets; Core as sole config/session source; parity audit.
16. Distribution: pinned Code-OSS and minimal reviewable patches, own branding,
    Open VSX, Linux builds and Windows-first installer/portable/upgrade/
    uninstall preparation, bundled runtimes, checksums/licenses; precompile
    and measured PackageCompiler experiment; no frequent repackaging.
17. Quality: meaningful unit/integration/multilingual repair E2E and graph
    oracle, CI, formatter/ambiguity/secrets/license/build gates, documented
    commands; layered A–G raw benchmark evidence, failure results retained.

## Scale and size

cloc counts authored `src/**/*.jl` Core only, with CLI reported separately.
Tests/docs/scripts/helpers/GUI/dependencies/inherited/generated files are
separate. No line padding, repeated templates, vendor code or unnecessary
abstractions. A module is complete only when implementation, errors, integration,
tests and documentation work. Line count is a delivery constraint, not proof
of model quality. No task-complete claim before both scope and size gates pass.

Planning allocations, not implemented code or a promise of artificial expansion:

| Core subsystem | Planning allocation (code lines) |
|---|---:|
| Model protocols, request pipeline, catalog/routing | 35,000 |
| Agent orchestration, context and recovery | 30,000 |
| Tools, processes, patches and Git | 25,000 |
| Permissions, budgets, sandbox and audit | 20,000 |
| Sessions, journals and scoped memory | 25,000 |
| MCP, skills, hooks and extension contracts | 25,000 |
| Project data, backend adapters and incremental state | 35,000 |
| Analyzers, queries, dynamic compute and profiling | 25,000 |
| Heterogeneous workers, durable tasks and mailboxes | 20,000 |
| Shared configuration, protocol and diagnostics | 10,000 |
| Total minimum planning allocation | 250,000 |

## Historical results (not reproduced evidence)

The design records 151 correct etcd package queries, ~12× warm Julia compute
but ~1.34 ms absolute saving versus ~1.72 s extraction, and slow Julia cold start.
The continuation records 1,094 files, ~25.6k symbols/~113.9k relations, global
adjacency overhead, and Python beating Julia on 194 package traversals
(~0.001612 vs ~0.001769 s). Later conversation records ~20 ms 1-file incremental
versus ~3.98 s full build, with caveats about snapshots/polling/global work.
These claims and negative results are retained as historical context. Raw
artifacts were not uploaded; no performance advantage is claimed for this rebuild.

## Storage and recovery

One main checkout, one shared toolchain, one dependency depot. Shallow reference
clones, no reference dependency installation unless specifically needed.
No full-directory copies/worktrees/tar backups on routine changes. Keep small
source checkpoints remotely; exclude reconstructible builds/caches/runtime
archives. Reserve 8 GiB before expensive builds and clean only named scratch
outputs. Verify each push with `git ls-remote origin refs/heads/main`.

## Validation classification

Use IMPLEMENTED_AND_VERIFIED, IMPLEMENTED_MOCK_VERIFIED, BLOCKED_EXTERNAL_API,
BLOCKED_EXTERNAL_PLATFORM and FAILED_NOT_COMPLETED. Missing live keys do not
block offline implementation. Missing Windows hardware does not excuse absent
Windows source/build preparation. Unimplemented features remain NOT_COMPLETED.
