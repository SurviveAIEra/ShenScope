# Julia runtime and project-data implementation contract

Rechecked against the uploaded design V3, section 7 (45 mechanisms), sections
8/9/18 and 39A.10–19; execution prompt sections 11–17; IDE continuation V3
priorities P0–P2 and sections 33–35; historical user/assistant discussion near
lines 12740–12765. Historical implementation and timing claims are not evidence
for the current source tree.

| Mechanisms | Required practical use | Current checkpoint |
|---|---|---|
| Multiple dispatch, traits, parametric types, union splitting | Typed provider/tool/backend/analyzer contracts; truthful capability negotiation | Provider/tool/backend/analyzer dispatch and real TypeScript compiler backend verified on small fixtures; broader semantic providers pending |
| Task, Channel, ScopedValue, Threads | Streams, tools, index/compute/test workers share cancellation, permission and budget | Agent/tool/RPC workers, durable leased tasks and context jobs verified; mailbox and additional worker profiles pending |
| Cmd, Process, pipelines, IO, sockets | Argument-vector processes with explicit ownership, bounded streams and cleanup | Owned process handles, Linux controlling PTY, native/VSIX terminal adapters and five model streams verified; restricted PTY and ConPTY pending |
| JIT, function barriers, specialization, immutable structs | Type-stable graph loops over resident data; measure first/warm time and allocations | Typed resident graph and raw nine-oracle timing/allocation evidence present; no performance advantage claimed |
| Reflection, ambiguity detection, compiler introspection | Inspect actual contracts/methods, inferred/lowered code and unstable types | Contract/ambiguity inspection, fixed-target structured inferred IR, bounded normal-control/local-definition/SSA projections and independently loaded package contracts verified; project inference pending |
| World Age, invokelatest, Module, Revise | Explicit trusted hot-load boundary; version/archive pointers for rollback | Child Module, latest-world calls, external tests, archive CAS rollback and installed-package activation/quarantine/deactivation verified; Revise and persistent activation pending; Module/World Age provide no sandbox |
| Expr, hygienic macros, generated functions, effect analysis | Bounded analysis intent/plans and dynamic-code risk classification | Bounded actual inferred Expr/SSA/slot operands and experimental Base.infer_effects predicates for fixed trusted Core targets implemented; macro/generated-function tooling pending; effect predicates provide no security boundary |
| Pkg, Manifest, extensions/weakdeps, Artifacts, Preferences | Reproducible, independently installable optional backends/plugins | Installed package UUID/version/source receipts, real Base.require, independently activated bundles and SparseArrays weakdep extension verified; marketplace/artifact distribution and persistent configuration pending |
| Precompilation, sysimage, PackageCompiler | Measure/install bundled runtime without requiring Julia knowledge | Actual generic Linux image build, source/dependency receipts, fresh-process metadata observations and real image-based RPC/model/extension tests verified; standalone distribution/relocation pending |
| FFI, cfunction/embedding | Reuse native parsers/libraries; isolate compiler/backend helpers | Linux x86_64 compute seccomp, inherited-descriptor closure, descriptor/shared-mapping audit and direct syscall refusal verified; general host-tool and other-platform isolation pending |
| Mmap, lazy iterators/AbstractArray, sparse arrays, SIMD | Bound memory, stream/query graph subsets and update local adjacency | Optional real sparse evidence matrices and bounded graph queries verified on fixtures; large-graph/Mmap/SIMD performance evidence pending |
| Logging scopes, Profile/Profile.Allocs, Test | Trace operations; compiler/performance evidence before optimization/promotion | Structured scoped events, actual fixed-Core @timed workloads, separate bounded Profile.Allocs samples and bounded periodic backtraces implemented across tool/CLI/RPC/both IDEs; arbitrary project, exclusive CPU/heap profiling and optimization evidence pending |
| GC, finalizers, WeakRef | Bounded caches with explicit external-resource cleanup | Explicit process cleanup, streamed frame replay and current-fact journal compaction verified on Linux; large-project cache measurements pending |
| File watching, timers/conditions/events, LibGit2 | Changes feed batched graph deltas and invalidate dependent queries | FileWatching/Task/Channel/Timers, recursive reconciliation, four-backend stable batches and Git CLI history/cochange evidence verified; a LibGit2 implementation remains optional |
| Distributed/RemoteChannel, GPU | Optional later execution backends with capability negotiation | Pending, outside the initial verified path |

Project data must expose stable symbol IDs, source ranges, relation evidence,
capabilities, revisions and deltas. The Core owns this stable model. CodeGraph
private schemas remain inside the adapter. Syntax and compiler-semantic results
must be labeled accurately, including unresolved/heuristic calls.

Resident state must maintain per-file facts, forward/reverse adjacency and
query invalidation locally. Each 1/5/20-file optimization requires a full rebuild
oracle on identical sources, raw timing/allocation evidence, and visible parse
failures that preserve the previous committed graph. CodeGraph's global relink
cost must be reported separately from local Core delta application.

One analyzer must run over Go AST, Tree-sitter and CodeGraph backends. A real
TypeScript compiler backend provides an additional semantic path. Ordinary
Julia functions return facts, ranked candidates, evidence and confidence;
the model retains engineering decisions. Generated analyzers need separate
OS/process isolation, no network/write access, bounded resources/output,
selftests and session-default lifetime before archival/promotion.

Checkpoint 036 adds a bounded canonical-fact join for installed Core self-inspection:
fresh JuliaSyntax declarations, owned compiler positions and actual allocation
stack samples retain hashes and independent identities. Containment witnesses
remain candidates, not runtime bindings or semantic equivalence. CodeGraph
private schemas are not required. Arbitrary workspace inference, additional
providers and project CPU/coverage/heap integration remain pending.

Checkpoint 037 adds actual `Profile` periodic helper backtraces for three fixed
Core fixtures. Buffer/retention/stack/inline-lookup bounds remain explicit;
inclusive frame fractions do not measure CPU utilization. Owned sampling reports
join the same canonical declaration/source facts without reexecution. The
bounded prefix does not establish whole-window or exclusive target attribution.
