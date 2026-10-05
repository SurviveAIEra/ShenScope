# Owned project diagnostics

The `problems` tool collects diagnostic reports from an existing project index,
retains bounded conversation-owned snapshots, filters and compares them, and
produces editor-compatible UTF-16 markers. It never assigns a made-up location
to a report without a source range. Julia implements the common contract; the
target project need not use Julia.

`capture` takes `backend`, optionally `paths` and `expected_revision`. Build the
index through the existing `project` tool first. `list`, `get`, `query`,
`compare`, `source` and `editor` refer to retained snapshot IDs. The same SDK is
exported as `capture_indexed_problems!`, `query_problem_snapshot`,
`compare_problem_snapshots` and `project_problem_editor_snapshot`.

The RPC namespace provides asynchronous `problems/start`, owned `problems/job`
and `problems/cancel`, and synchronous `problems/query`. Ask permissions use
asynchronous operations, keeping the RPC reader free to answer approvals.
Poll/cancel require the owning session, root and state directory. A current
Read denial withholds retained job results and completion-event data.

Every capture reads each selected source under Read permission and compares its
SHA-256 with the index. Workspace paths reject protected files and symlinks;
bounded reads check file identity before and after. Publication checks current
source bytes and compiler configuration again. Changed, missing or unavailable
sources produce no editor markers. A newly appearing configuration invalidates
a snapshot that recorded its absence. Client publication must also verify its
open editor buffer, because unsaved text can differ from on-disk bytes.

Core ranges use one-based UTF-8 byte columns, with an exclusive end. Editor
ranges use zero-based lines and UTF-16 character offsets. Half-surrogate and
partial UTF-8 coordinates are rejected. Source previews carry the verified hash.
Stable diagnostic IDs identify report content and location, excluding source
hash, so an unchanged diagnostic can be compared across source revisions.

Defaults: 512 files, 4,096 items, 256 per file, 16 KiB per message, 8 MiB per
source, 32 MiB total source reads, 3 MiB serialized snapshots and 16 MiB retained
memory. At most 32 snapshots survive in a manager. Selection/item limits report
omissions; oversize serialized results fail explicitly. Snapshots do not survive
process restart and reading them never runs a command or a model.

Current specialized producers are TypeScript 5.9.2 semantic diagnostics and
JuliaSyntax parse diagnostics. Backends without a diagnostic capability report
that fact; an empty result does not imply the entire project is clean. The
common format also receives versioned language-server reports, selected compiler/
linter output and imported SARIF. Both editor clients publish the Core editor
projection into the native Problems view. Comparing disappearing rows reports a change in producer
reports, not independent proof that a bug was fixed.

The shared publisher verifies owning session/root/snapshot identity and bounded
UTF-16 ranges. It queries Core before and after asynchronous source reads and
hashes each current editor buffer twice, using disk only for unopened sources.
Unsaved text, stale disk/configuration, unavailable sources and invalid ranges
withhold markers. Publication never executes a producer, fix or model call;
capturing an existing project index uses an owned cancellable Core operation.
Use Project's **Show in Problems** and **Clear Problems**, or the same action
on a tool result containing an owned Problems snapshot.

VSIX owns a DiagnosticCollection; the native Workbench owns an IMarkerService
source. Both use `shenscope.core.problems` and clear only their own markers.
File/buffer changes, session/configuration changes, transport closure, explicit
clear and disposal withdraw affected markers. The native client can do this
with all extensions disabled. Publishing cached projections requires effective
Read Allow; one-time approval of capture does not grant future synchronous reads.
Clients read at most 8 MiB/file, 32 MiB on the first pass and 64 MiB across both
passes. A buffer whose decoding/BOM differs from recorded UTF-8 bytes is withheld.
Automatic producer execution, unsaved-buffer indexing, automatic fixes, complete
dependency freshness and installed cross-platform IDE distribution remain absent.

Validation: `julia --threads=4 --project=. test/problems.jl`. It uses a real
TypeScript checker plus owned-source, permission, cancellation, Unicode,
configuration and retention cases. No live-model programming claim is made.
