# Combined project evidence

Julia Core can compare, search and traverse saved indexes from two or more
project backends. The tool, CLI and both editors use the same implementation.
Sources must be indexed explicitly first. Combining them reads their saved
facts and source files; it does not start parser helpers, evaluate project
code, run tests, query Git or call a model.

## Identity and provenance

Every symbol and relation retains its native identity, backend name, revision,
source range and indexed source hash. Combined keys namespace native IDs by
backend. A native ID collision between providers never merges declarations.
Backend capability claims remain separate from runtime confirmation.

An anchor groups declarations only when file, source SHA-256, complete UTF-8
range, qualified name and normalized declaration family match. Function/method
and type/class/struct families can share anchors. File symbols and empty ranges
are excluded. Multiple members from the same backend make an anchor ambiguous
and disable traversal through it. Different extraction ranges are retained as
separate observations. Anchors do not establish runtime binding equivalence.

Comparison exposes each provider's signature, kind and outgoing relation
counts/kinds. Disagreement never selects an automatic winner. Missing relations
can reflect extraction granularity; they are not proof that a dependency is
absent. Source hashes that disagree for the same file refuse the whole capture.

## Actions

`evidence_status` lists the five built-in backends and whether saved or loaded
indexes exist. Status does not verify every indexed source hash. The four
analysis actions are asynchronous through `project/start` in the editor RPC:

| Action | Result |
| --- | --- |
| `evidence_compare` | Exact anchors with separate provider observations |
| `evidence_search` | Bounded lexical ranking of independently identified symbols |
| `evidence_impact` | Reverse reachability from changed files or combined symbol keys |
| `evidence_tests` | Test-named observations reached through the combined graph |

Example CLI after indexing the same workspace with Go AST and Tree-sitter:

```sh
shenscope project evidence_compare --backends go_ast,tree_sitter --limit 20 --json
shenscope project evidence_tests api.go --backends go_ast,tree_sitter --max-depth 6 --json
shenscope project evidence_search Api --backends go_ast,tree_sitter --json
```

For impact/tests, `paths` contains changed-file seeds; `scope_paths` optionally
limits graph capture. Compare/search use `paths` as their capture filter. The
default is the whole bounded indexed graph, so changed-file selection does not
accidentally exclude callers. A capture filter can exclude callers outside it.
`evidence_keys` selects namespaced symbols explicitly. Every selected changed
file or key must belong to the captured graph.

Traversal follows supported dependency relations with an explicit witness.
Optional exact-source anchor steps are shown alongside provider edges, consume
one depth level and carry heuristic weight 0.9. A relation's confidence is its
provider value; path confidence is the minimum step value. The first bounded
breadth-first witness is retained, not an exhaustive best-confidence path.
Multiple observations of a declaration remain separate candidates. Naming and
static reachability do not prove test coverage or runtime execution.

## Consistency, permissions and resource limits

Capture uses each index's mutex and returns a detached snapshot. It verifies
source revision vectors, selected hashes, compiler configuration and current
file bytes before analysis and before returning the result. All captured symbol
and relation ranges are checked against the verified UTF-8 SourceMap. Expected
revision vectors and a fingerprint support refusal of changed pagination
snapshots. This is not an atomic transaction across index updates and editor
filesystem writes, and trusted in-process snapshots contain mutable collections.

Read authorization covers the composite operation once. Cancellation, shared
budget expiry and live read denial remain checkpoints during capture,
verification and traversal. Existing session ownership, approval cancellation
and one-running-project-job rules apply. Saved facts are loaded under this read
authorization without process, network or persistence grants.

Defaults allow eight sources, 20,000 symbols, 100,000 relations and depth eight
(maximum 32). Current built-in source selection supports five backends. Capture
is bounded by 4,000 files, 8 MiB serialized evidence and 32 MiB verified source
reads. Serialized accounting is not a physical RSS ceiling. Pages are limited
to 1,000 items and 3 MiB of item serialization; oversized individual entries
refuse the request. The common project transport also bounds the final envelope.

Git history, imported coverage, runtime traces, compiler-confirmed Julia facts,
cross-project identities and generated analyzers over combined snapshots remain
separate pending capabilities. This checkpoint does not complete those handoff
requirements or the authored Core size target.
