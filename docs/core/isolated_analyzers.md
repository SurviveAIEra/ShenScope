# Isolated Julia analyzer candidates

Dynamic analyzer source is evaluated only in a separate Julia process. The
parent sends source and explicit JSON inputs after validating the trusted
bootstrap's ready frame. Source is never evaluated in the agent, server or IDE
process. An ordinary Julia Module is used to organize definitions inside that
child; it supplies no security boundary.

The Linux compute profile uses libseccomp with a default EACCES action, thread
synchronization and no-new-privileges. It permits runtime memory, timing, signals
to the same process, synchronization and audited anonymous IPC. It does not
permit filesystem opens/mutations, sockets, process creation/exec, descriptor
duplication/receipt, tracing, cross-process memory or io_uring. Julia's existing
anonymous LLVM code memfd can be mapped/resized within a 128 MiB hard file-size
limit. That RAM object has no host filesystem pathname. No writable host file
descriptor is admitted. `/dev/null` is checked as the actual Linux device.

A small isolated-mode Python exec launcher closes every inherited non-stdio
descriptor before starting Julia. Python owns no agent/analyzer logic. The
trusted Julia bootstrap then audits its newly created runtime descriptors;
stdio must be pipes. The child environment contains explicit runtime settings,
PATH and the shared Julia depot, without inherited model keys or startup hooks.
Launcher identity is rechecked after asynchronous permission approval.

Each child receives hard CPU, virtual-address-space, core-dump and memfd size
limits before the filter is installed. Parent checks bound wall time, input,
combined protocol output and diagnostics, enforce cancellation and permission
revocation, and reap the process group and streams. CPU accounting includes
trusted bootstrap; virtual address space is not a resident-memory quota. Parent
process buffers stay bounded even when caller code floods stdout. There is no
permissive fallback: unavailable enforcement or a failed bootstrap rejects the
operation before source delivery. Linux x86_64 is the verified platform;
macOS/Windows are unavailable and aarch64 has not been runtime-tested.

## Candidate contract

Define `analyze(data, request)::Dict` and `selftest()::Bool`. JSON dictionaries,
arrays, strings, finite numbers, booleans and null are the data boundary. Base
and preloaded runtime modules are available; filesystem/package loading after
bootstrap is unavailable. New methods are inspected and called through
`invokelatest`, including contract reflection, to handle Julia World Age.

The parent compares each external fixture's actual dictionary with its expected
canonical JSON. Expected outputs are not sent to the child. A successful
`selftest()` alone does not validate a candidate. Evaluation reruns external
fixtures and rejects mismatches before publishing the actual result. Receipts
bind source, version, fixture inputs/expectations, actual result hashes, limits
and enforced sandbox. Supplied fixtures establish agreement for those cases;
they do not prove general correctness. Child compile/analyze timing counters
are untrusted observations; parent elapsed time includes startup and validation.

Registrations are session-scoped, hash-addressed and bounded by record, byte and
concurrent execution caps. Registering another version does not silently replace
the selected version. Inspection returns copies. In-flight runs have child
cancellation tokens and shared budgets; cancellation leaves the owning agent
context active. Removing a running candidate requires cancellation first.
Permission checks cover read, dynamic-code admission and process execution.

The `analyzers` model tool also exposes catalog, graph run, archive, versions,
archive inspection, restore, promotion, rollback and pointer history. Read,
dynamic-code and persistence approvals remain independent. This compute profile
does not supply general host-tool isolation.

## Indexed project inputs and grounded results

`IsolatedJuliaAnalyzer` implements the ordinary `AbstractAnalyzer` interface.
It receives bounded, detached JSON facts from the selected Go AST, Tree-sitter,
CodeGraph or TypeScript compiler backend. Requests can select paths/symbols,
direction and depth. Whole graphs above the requested capacity require explicit
seeds; bounded projections report their scope and truncation. The parent binds
revision, project fingerprint, backend, file hashes and actual fact identities.

Graph results contain `candidates`, optional `notes` and `truncated`. A candidate
contains exactly `symbol_id`, `score`, `confidence`, `reason` and `evidence`.
Scores/confidence must be finite numbers in [0, 1]; evidence lists known relation
IDs connected to that candidate. Empty evidence allows confidence zero only.
Confidence cannot exceed the minimum confidence of its recorded evidence.
An optional seed-connectivity requirement uses undirected indexed adjacency.
Unknown IDs, invented locations, disconnected evidence and additional candidate
fields are rejected. The parent attaches original locations and provenance and
checks that the indexed revision/fingerprint still match before publication.

Reasons, scores and conclusions remain generated hypotheses. Connectivity and
confidence bounds are consistency checks, not proof of algorithm correctness or
runtime behavior. Facts describe the indexed snapshot; saved files can change
without a refreshed index. The result explicitly records these limitations.

## Immutable archives and active pointers

Project archives are bound to the canonical workspace within the configured
Core state directory. User archives belong to that state directory and can be
restored into another project explicitly. Both contain immutable JSON manifests
with source/tests/limits, their hashes and historical receipts. No Core source
files or complete project directories are copied. Retention has hard version and
byte capacities; automatic pruning and version deletion are not implemented.

Archiving does not require a passing validation and does not select that version.
Restoring registers a session candidate and never trusts an archived receipt as
current execution validation. Promotion and rollback run external fixtures in a
fresh isolated child, then request persistence approval and atomically compare
the expected active-pointer revision before publication. Conflicting pointers
reject publication. Failed validation cannot replace an active version.
Rollback selects an archived immutable version; it does not erase Julia methods
or modify the trusted Core. Pointer history records separate logical revisions,
previous versions, fixture identity, source identity and the Core version.
Contended archive transactions check cancellation, budgets and revoked policy
while waiting and after lock acquisition.

## RPC and editor controls

`analyzers/query` returns read-authorized metadata and paged archives. Mutations
and computations start with `analyzers/start`; `analyzers/job` polls retained
results and `analyzers/cancel_job` cancels only the owning conversation's child
context. Completed/failed events carry the same job identity. Registry/job
retention and output sizes are bounded. Active operations block configuration
replacement and starting another agent run in that conversation. Configuration
replacement and shutdown drain owned resources and clear session candidates.

Both editor clients share the Analyzers view: indexed backend availability,
session candidates and selected versions, source/external-fixture inspection,
validation, grounded project results and file navigation, immutable archives,
CAS promotion/rollback and pending-operation cancellation. Unsupported isolation
is visible and execution controls are disabled. These controls use Julia RPC;
the clients do not run custom analyzer source.

## CLI

```sh
shenscope analyzers status --root /path/to/project
shenscope analyzers validate DEFINITION.json --root /path/to/project \
  --allow-dynamic --allow-process
shenscope analyzers evaluate DEFINITION.json INPUT.json --root /path/to/project \
  --allow-dynamic --allow-process
shenscope analyzers archive DEFINITION.json --allow-dynamic --allow-persistence
shenscope analyzers promote DEFINITION.json --expected-pointer 0 \
  --allow-dynamic --allow-process --allow-persistence
shenscope analyzers versions NAME --scope project
shenscope analyzers inspect NAME VERSION
shenscope analyzers history NAME
shenscope analyzers run DEFINITION.json --backend go_ast \
  --allow-dynamic --allow-process
shenscope analyzers run-archive NAME VERSION --backend go_ast \
  --allow-dynamic --allow-process
shenscope analyzers rollback NAME VERSION --expected-pointer 1 \
  --allow-dynamic --allow-process --allow-persistence
```

CLI reads bounded workspace-confined definitions and inputs, registers a
candidate for that invocation, runs the same implementation, prints JSON and
cleans the registry. `run`/`run-archive` use an existing index; index it with
`shenscope project build` first. Their optional final request JSON supplies graph
limits/seeds, rather than arbitrary input data. `restore NAME [VERSION]` defaults
to the active archived version. Archive pagination uses `--offset`/`--limit`.
Validation exits with code 1 when external fixtures fail.
Source symlinks and protected paths are rejected. The fixture example under
`examples/analyzers` is excluded from authored Core line counts.

## Verification

`test/unit/compute_protocol.jl`, `test/unit/analyzers.jl`,
`test/integration/compute_isolation.jl` and `test/integration/analyzers.jl`
cover the wire contract, source integrity, ownership, actual kernel calls,
descriptor inheritance, running cancellation, output flooding and external
fixture disagreement. The full affected suite exercises the shared in-memory
JSON parser and tool registration. No live-model quality claim follows from
these local process tests.

Additional graph, archive, backend, RPC and CLI tests are in
`test/unit/analyzer_graph.jl`, `test/unit/analyzers_protocol.jl`,
`test/integration/analyzer_archive.jl`, `test/integration/analyzer_backends.jl`
and `test/integration/analyzer_cli.jl`. `ide/test/native_smoke.mjs --analyzers-only`
checks the native window, and its `--vsix` variant checks the independent webview.
Checkpoint evidence distinguishes successful final runs from earlier failed
test attempts; it does not infer Windows, installed-package or live-model results.
