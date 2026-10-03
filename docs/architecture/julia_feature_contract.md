# Julia runtime and project-data implementation contract

Rechecked against the uploaded design V3, section 7 (45 mechanisms), sections
8/9/18 and 39A.10–19; execution prompt sections 11–17; IDE continuation V3
priorities P0–P2 and sections 33–35; historical user/assistant discussion near
lines 12740–12765. Historical implementation and timing claims are not evidence
for the current source tree.

| Mechanisms | Required practical use | Current checkpoint |
|---|---|---|
| Multiple dispatch, traits, parametric types, union splitting | Typed provider/tool/backend/analyzer contracts; truthful capability negotiation | Provider/tool/backend/analyzer dispatch verified; compiler-semantic backend pending |
| Task, Channel, ScopedValue, Threads | Streams, tools, index/compute/test workers share cancellation, permission and budget | Agent/tool/RPC workers and scoped context verified; durable tasks pending |
| Cmd, Process, pipelines, IO, sockets | Argument-vector processes with explicit ownership, bounded streams and cleanup | Process/tools and five model streams verified |
| JIT, function barriers, specialization, immutable structs | Type-stable graph loops over resident data; measure first/warm time and allocations | Typed resident graph and raw nine-oracle timing/allocation evidence present; no performance advantage claimed |
| Reflection, ambiguity detection, compiler introspection | Inspect actual contracts/methods, inferred/lowered code and unstable types | Contract/ambiguity inspection and fixed-target compiler diagnostics verified; independent extension examples pending |
| World Age, invokelatest, Module, Revise | Explicit trusted hot-load boundary; version/archive pointers for rollback | Permissioned invokelatest for loaded trusted callables verified; load/archive/rollback pending; Module/World Age provide no sandbox |
| Expr, hygienic macros, generated functions, effect analysis | Bounded analysis intent/plans and dynamic-code risk classification | Pending; ordinary functions first, no unrestricted Core eval |
| Pkg, Manifest, extensions/weakdeps, Artifacts, Preferences | Reproducible, independently installable optional backends/plugins | Manifest pinned; independent extension/artifact contracts pending |
| Precompilation, sysimage, PackageCompiler | Measure/install bundled runtime without requiring Julia knowledge | Shared verified toolchain/setup present; standalone distribution pending |
| FFI, cfunction/embedding | Reuse native parsers/libraries; isolate compiler/backend helpers | Native durable storage APIs and real parser/database adapters verified; hostile-input OS isolation pending |
| Mmap, lazy iterators/AbstractArray, sparse arrays, SIMD | Bound memory, stream/query graph subsets and update local adjacency | Pending large-graph evidence; no synthetic duplicate-edge scale claims |
| Logging scopes, Profile/Profile.Allocs, Test | Trace operations; compiler/performance evidence before optimization/promotion | Structured scoped events and meaningful tests present; profiling pending |
| GC, finalizers, WeakRef | Bounded caches with explicit external-resource cleanup | Explicit process cleanup and graph journal/frame limits present; large-project cache management pending |
| File watching, timers/conditions/events, LibGit2 | Changes feed batched graph deltas and invalidate dependent queries | Git CLI present; watcher/history adapters pending |
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
