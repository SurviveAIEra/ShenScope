# Project data and analysis

The Julia Core owns `CodeSymbol`, `Relation`, `SourceRange`, `FileFacts`,
`BackendCapabilities`, the resident `ProjectState`, its journal and analyzers.
Parser-specific node IDs and database schemas stay inside backend adapters.
Syntax declarations have stable IDs derived from path, kind, qualified name,
signature and duplicate ordinal. Moving lines preserves identity; renaming or
changing a signature can change it. Ranges use one-based UTF-8 byte columns.

## Real backends

| Backend | Actual dependency | Current limits |
|---|---|---|
| `go_ast` | Compiled helper using Go `go/parser` and `go/ast` | Go syntax; unique-name call candidates, no type checking |
| `tree_sitter` | Native Tree-sitter grammars through language-pack 1.20.0 | Seven languages, partial declaration/call extraction, no compiler semantics |
| `codegraph` | CodeGraphContext 0.6.13, pinned commit `642c3215f8ef87fba03bc5dea6dbcb28d655fbd8`, Ladybug 0.19.1 | Six languages; source-bound nodes/relations; global call/inheritance relink and export remain |
| `typescript` | TypeScript 5.9.2 language service/checker | Single workspace program; semantic types/references/calls/diagnostics; restricted external dependencies; see [semantic.md](semantic.md) |

The CodeGraph adapter invokes the actual SDK `GraphBuilder.parse_file`,
`pre_scan_imports`, graph writers, `link_function_calls` and `link_inheritance`.
It is not a replacement database marketed as CodeGraph. SDK global nodes with
no source path are currently omitted. Detailed compiler diagnostics, types and
reference completeness are not implemented. Parsing errors reject an update
and preserve the last committed Core graph.

The authored Python and Go helpers are small dependency transports/extractors.
Graph identity, invalidation, persistence, queries, permissions and analysis
remain Julia functions. They do not execute indexed project source. This does
not yet constitute an OS sandbox for hostile native parser input.

## State and incremental updates

Each file owns its facts and edges. The Core keeps forward/reverse adjacency,
declaration-name buckets and referencing-file buckets resident. A changed name
relinks files that mention it; unrelated adjacency is retained. Qualified or
ambiguous syntax calls remain unresolved. Unique local/global syntax candidates
have confidence 0.65/0.45, respectively; these values express heuristic strength,
not calibrated runtime probabilities.

Source hashes are checked before extraction and again before persistence.
Validation completes before append. A checksummed begin/file/commit transaction
is flushed once; interrupted transactions disappear during replay. Incremental
writes compare known journal size under an OS lock rather than replaying the
entire journal. A fresh CLI or editor can query the journal without starting a
parser worker. External writers require a reload after conflict.

Limits are explicit: 10,000 indexed files, 8 MiB per source, 32 MiB helper frames,
bounded helper stderr and timeout, and 128 MiB per backend journal. A limit
failure preserves the committed state. File watching and large-project streaming
remain unfinished. Explicit derived-journal compaction and streaming replay are
described in [project_storage.md](project_storage.md). The compiler semantic backend
and its narrower 24 MiB source-snapshot limit are described in `semantic.md`.
Compact obsolete index transactions when a journal reaches capacity. A snapshot
that exceeds capacity requires a different indexing scope; facts are not discarded.

CodeGraph's database is a disposable, adapter-owned derived cache. It is closed
and removed on normal worker exit. A marker identifies abandoned cache directories
from dead workers; only those are eligible for cleanup. The Core journal remains
authoritative. Source folders and whole project checkouts are never copied.

## Analysis and clients

`ImpactAnalyzer` returns bounded reverse-relation traversal with evidence IDs,
depth, score and confidence. `TestSelectionAnalyzer` filters reachable or directly
changed test-named symbols; it has no coverage proof. `ArchitectureAnalyzer`
computes file dependency cycles and hubs with an iterative SCC traversal.
The same ordinary Julia implementations operate on all four backends.
The model and user retain decisions about which changes/tests are appropriate.

```sh
bash scripts/setup.sh --backends --editors
bin/shenscope project build --backend go_ast --root . --state-dir .local/state --allow-process --allow-persistence
bin/shenscope project search Greet --backend go_ast --root . --state-dir .local/state
bin/shenscope project test_selection src/example.go --backend go_ast --root . --state-dir .local/state
```

`scripts/setup_backends.py` uses one shared SDK checkout, Python environment,
Go compiler/helper and grammar cache. Alternate installations can use
`SHENSCOPE_TOOLS_DIR`, `SHENSCOPE_REFERENCES`, `SHENSCOPE_PARSER_CACHE`; runtime
helper overrides are `SHENSCOPE_PARSER_PYTHON` and `SHENSCOPE_GO_HELPER`.
The setup writes their non-secret paths into `shenscope-backends.json` and the
CI environment. Desktop/runtime dependencies are not bundled in the VSIX yet.

The native Workbench and VSIX Project view selects backends, indexes with actual
Core approvals, displays snapshot counts, searches/jumps to symbols, and runs
impact/test/architecture analysis. Async project jobs have their own cancellation
and trace IDs; conversation messages remain separate. Configuration changes are
rejected while an agent or project job is running.

## Evidence

`test/project_data.jl` runs real dependencies, not a mock CodeGraph implementation.
The 21-file fixture compares 1/5/20-file changes with fresh full builds for each
backend: nine equal graph oracles. It also covers deletion, syntax failure,
journal recovery, ambiguous calls, cross-file invalidation, cycles and scope.
Raw timings/allocations are in `docs/validation/project-oracles-006.json`.
They include small-fixture/JIT effects and establish no competitive advantage.
Protocol tests cover approvals, cancellation, configuration ownership, cache
reload without parsers, deny rules and storage capacity. Actual native and VSIX
GUI smoke tests exercise an installed Go parser through the Project view.
