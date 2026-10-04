# Graph-based migration proposals

`MigrationAnalyzer` computes a review proposal from recorded project facts. It
does not edit source, schedule work, execute tests or validate API compatibility.
Julia owns graph selection, cycle condensation, dependency layers, IDs, limits
and evidence; native Workbench and VSIX render the same result.

## Selection and identity

At least one indexed path/symbol seed is required, with 128 seeds maximum.
Selection uses the existing permissioned, versioned analyzer graph snapshot in
the reverse direction. Default depth is eight; symbols default to 5,000 (20,000
maximum), relations to 20,000 (100,000 maximum), files to 256 (512 maximum).
The snapshot captures source hashes, symbol/relation IDs, capabilities, revision
and a whole-index fingerprint. Its mutex is released before proposal work.
Revision, fingerprint, scope, budget, cancellation and permission are checked
before return. CPU checkpoints yield to allow other Julia Tasks to run.

Depth/node limits report an incomplete neighborhood. Reaching a depth boundary
with an unvisited relevant neighbor now marks ordinary graph traversal as
truncated; this correction also applies to Impact and isolated-analyzer graph
snapshots. A cycle already fully visited does not alone imply truncation.

A plan ID hashes workspace, index fingerprint/revision, seed IDs, selected
symbols, intent, ordering, confidence filter, depth/truncation and full batch
constraints. It is stable for the same input. A source/index change retires it.
Display limits do not change the full proposal's ID. IDs are not durable task
leases or receipts, and no plan registry is created.

## Batches and evidence

Calls, imports, inheritance, implementation and reference relations become
directed file dependencies: source file depends on target file. Internal
same-file relations do not create another file constraint. A configurable
minimum confidence (0–1, default zero) excludes lower-confidence relations and
reports their count. Selection still describes the captured neighborhood; a
filtered relation does not erase its already-selected file.

Iterative strongly connected components merge inter-file cycles into one
coordinated review batch. Architecture uses the same validated algorithm. The
condensed graph supplies deterministic layers:

- `dependency_first`, default: dependency batches precede callers.
- `callers_first`: caller batches precede dependencies.

Both are ordering strategies over evidence. Neither guarantees a safe API
change. Change kind is `signature` (default), `rename`, `remove`, `move` or
`behavior`; the first four explicitly flag compatibility review. Every batch
requires review. Cycle groups are not filesystem transactions.

Batch output contains file hashes/seed flags, prerequisite IDs, relation kinds,
minimum recorded confidence, source/target IDs, provenance and source ranges.
Each batch retains 64 dependency summaries and eight witnesses per summary,
reporting omissions. Up to 32 selected test-named symbols are candidates, with
omitted counts. Naming is not coverage or test execution evidence. The retained
step limit defaults to 100, maximum 1,000, with a separate 3 MiB batch payload
cap. Truncated previews remain `partial_proposal`; other results remain
`review_proposal`. `writes_performed`, `tests_executed` and
`execution_registered` are always false.

Unknown, dynamic and external calls can hide affected code. Backend capability
declarations and per-relation provenance delimit the evidence. A semantic
compiler relation remains a static observation. No migration is declared
complete by a graph ordering.

## Interfaces

The ordinary Project tool action is `migration`. CLI reads an existing cache
with read permission; it does not launch a parser or process during planning:

```bash
shenscope project build --backend go_ast --allow-process --allow-persistence
shenscope project migration src/api.go --backend go_ast --change-kind signature --order dependency_first
shenscope project migration --symbol SYMBOL_ID --max-depth 4 --minimum-confidence 0.5
```

Additional CLI bounds are `--max-files`, `--max-symbols`, `--max-relations`,
`--limit`, `--revision`. RPC uses conversation-owned asynchronous `project/start`,
`project/job` and `project/cancel`. Example fields:

```json
{"session_id":"<conversation>","backend":"go_ast","action":"migration","paths":["src/api.go"],"change_kind":"signature","order":"dependency_first","max_depth":8,"minimum_confidence":0.0}
```

Synchronous `project/query` does not start planning. Both IDE clients expose
change/order/depth controls, cycle and prerequisite batches, source links,
relation disclosure and partial coverage. Proposals do not mutate a checklist
into completed work.

## Validation scope

Independent reachability oracles validate SCC grouping and insertion-order
stability. Synthetic graph fixtures validate both ordering strategies, cycles,
evidence, test candidates, confidence filtering, bounds, denial and freshness.
Real Go AST, Tree-sitter, CodeGraph and TypeScript compiler fixtures agree on
the expected file cycles and batches; a body edit/index update changes the plan
ID. CLI/RPC replay a saved real graph while process/network/persistence are
denied. Actual Workbench/VSIX flows validate cycle evidence, reversed order,
depth-zero partial output and native source opening without model requests.

Cold Julia initialization exceeded client startup limits in part of the
concurrent validation; failed attempts are retained. Boot/precompile measurement
is a separate next step. Automated edits, durable execution, installed desktop/
VSIX and Windows runtime validation remain pending. The 250,000 authored Core
line target remains active and unmet.
