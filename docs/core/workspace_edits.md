# Reviewed workspace edits

The `workspace` tool prepares bounded multi-file source proposals. Preparation
requires Read and validates hashes, UTF-8 byte ranges, text capacity, unique
paths and non-overlapping edits. It writes no project files. Each proposal has
an owner, title, source versions, content-derived manifest hash and new identity.

`list`, `get`, `preview` and `source` inspect owned proposals. Preview uses an
independent bounded shortest-edit search and unified display. Distance/memory
limits can fall back to a clearly labelled contiguous display; output/hunk/file
omissions are reported. Header labels are display strings, not shell/external
patch instructions. Source content is historical proposal content, not a claim
that it is current disk text.

`apply` requires the plan ID and reviewed plan hash. It approves all file edits
and rechecks all sources before the first write. Shared file locks match the
ordinary edit/write tools. Each file is staged and atomically replaced after
another source/path/mode check. The ordinary `edit`/`patch` tools now use this
common implementation for literal replacements, preserving their return shape.

Ordinary failures report `not_applied`, `rolled_back` or `partial`. Rollback
checks that each destination still has the bytes this operation wrote, preserving
external modifications and reporting conflicts. Cancellation does not skip
rollback, but revoked permissions remain effective. Receipts are retained before
notification; a lost UI event cannot undo writes or enable repeated application.

This is not a multi-file power-loss transaction, an external-process CAS primitive
or an OS sandbox. Concurrent external writers can race between checks and OS
replacement. Applied/discarded/failed proposal states cannot be applied again.

`verify` takes the applied plan/hash, test catalog ID and explicitly selected
candidate IDs. It checks edited source hashes before/after actual test execution
and associates plan, application, run-set and command receipts. It does not
snapshot every project input or prove complete coverage. A command can already
have run when verification becomes unconfirmed; no implicit retry is performed.

`verify_check` applies the same lifecycle to a compiler/linter command rather
than a discovered test candidate. Pass the applied plan/hash and explicit
`argv`, with optional `cwd`, output `family`, `column_unit`, label and timeout.
It checks only the edited source versions before and after the command, then
binds application, validation, Problems and actual execution receipt hashes.
The shared tool set uses the same testing/validation/Problems managers. Process
approval remains separate from applying an edit; failure leaves the proposal
applied, or verification unconfirmed if command effects cannot be established.
It does not automatically reapply edits or rerun commands.

`history_save/list/get/sources/restore/delete` use a bounded versioned store.
Saving and deleting require Persistence as well as Read and expected revisions.
The store saves necessary replacement text/ranges, manifests and receipts,
without source backups. Only pending proposals can be restored: all current
source files are checked and a new proposal identity/hash requires explicit apply.
Saved executed results are historical evidence and never replay commands/writes.
Source inspection reports matches-before/after/both, changed, missing or unavailable;
a matching source hash does not independently prove historical command success.
Deletion is a versioned tombstone, not secure erasure.

Default in-memory limits: 64 files, 2,048 edits, 4 MiB/file, 32 MiB combined
before/after content, 8 MiB replacements, 16 proposals and 64 MiB retained text.
Preview is at most 128 KiB. Explicit history has 64 keys including tombstones,
120 KiB per record, 8 MiB journal and two revisions. Oversized proposals may be
usable in memory while too large to save; saving fails before altering history.
Busy applying/verifying proposals cannot be saved or retired.

RPC: `workspace/start/query/job/cancel`. Query is limited to approved reads;
other actions use owned asynchronous operations. Plan mode allows inspection,
preparation/discard and read-only restoration, but not apply/test execution or
persistent writes. Root/state/session checks also apply to exported SDK methods.

```sh
julia --startup-file=no --threads=4 --project=. test/workspace_edits.jl
julia --startup-file=no --threads=4 --project=. test/project_workflow_protocol.jl
```

Actual Python/JavaScript repair tests associate failing commands, source edits,
application receipts and passing selected checks. Unicode difference tests
reconstruct both source sides; stale, overlapping, foreign, rollback-conflict,
notification-loss, saved-history restart/CAS/tampering cases are included.
